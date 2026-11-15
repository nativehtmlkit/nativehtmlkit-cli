//! Local byte stream to the Core host with a deadline on every read and write.
//!
//! Unix: `AF_UNIX` stream with socket timeouts. Windows: the named pipe is opened for
//! overlapped I/O so a read can be abandoned after a timeout (a synchronous pipe handle
//! cannot be interrupted, and would also serialize a blocked read against a write).
use std::io;
use std::time::{Duration, Instant};

#[derive(Debug, PartialEq, Eq)]
pub enum ReadStatus {
    Data(usize),
    /// Nothing arrived within the timeout; nothing was consumed.
    TimedOut,
    /// The peer closed the connection.
    Closed,
}

/// A wait allowance that is only reduced by time actually spent waiting in this process.
/// A timed-out wait costs exactly its timeout, so a suspended machine (where wall and
/// monotonic clocks can jump on resume) cannot exhaust the allowance without waiting.
#[derive(Clone, Copy, Debug)]
pub struct Budget(Duration);

impl Budget {
    pub fn new(total: Duration) -> Self {
        Self(total)
    }
    pub fn left(&self) -> Duration {
        self.0
    }
    /// Charge a wait that was asked to last at most `requested`.
    pub fn charge(&mut self, requested: Duration, started: Instant, timed_out: bool) {
        let spent = if timed_out {
            requested
        } else {
            started.elapsed().min(requested)
        };
        self.0 = self.0.saturating_sub(spent);
    }
}

const MIN_WAIT: Duration = Duration::from_millis(1);

pub struct Stream {
    inner: platform::Inner,
}

impl Stream {
    /// Connect, retrying briefly while the host is still creating its endpoint.
    pub fn connect(endpoint: &str, patience: Duration) -> io::Result<Self> {
        let started = Instant::now();
        loop {
            match platform::Inner::open(endpoint) {
                Ok(inner) => return Ok(Self { inner }),
                Err(error) if error.kind() == io::ErrorKind::PermissionDenied => return Err(error),
                Err(error) if started.elapsed() >= patience => return Err(error),
                Err(_) => std::thread::sleep(Duration::from_millis(60)),
            }
        }
    }

    pub fn read(&mut self, buffer: &mut [u8], timeout: Duration) -> io::Result<ReadStatus> {
        debug_assert!(!buffer.is_empty());
        self.inner.read(buffer, timeout.max(MIN_WAIT))
    }

    /// Write everything or fail; `ErrorKind::TimedOut` when the peer stops reading.
    pub fn write_all(&mut self, bytes: &[u8], timeout: Duration) -> io::Result<()> {
        self.inner.write_all(bytes, timeout.max(MIN_WAIT))
    }
}

#[cfg(unix)]
mod platform {
    use super::ReadStatus;
    use std::io::{self, Read, Write};
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    pub struct Inner(UnixStream);

    fn timed_out(error: &io::Error) -> bool {
        matches!(
            error.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        )
    }

    impl Inner {
        pub fn open(endpoint: &str) -> io::Result<Self> {
            UnixStream::connect(endpoint).map(Self)
        }

        pub fn read(&mut self, buffer: &mut [u8], timeout: Duration) -> io::Result<ReadStatus> {
            self.0.set_read_timeout(Some(timeout))?;
            loop {
                return match self.0.read(buffer) {
                    Ok(0) => Ok(ReadStatus::Closed),
                    Ok(n) => Ok(ReadStatus::Data(n)),
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) if timed_out(&e) => Ok(ReadStatus::TimedOut),
                    Err(e) if e.kind() == io::ErrorKind::ConnectionReset => Ok(ReadStatus::Closed),
                    Err(e) => Err(e),
                };
            }
        }

        pub fn write_all(&mut self, mut bytes: &[u8], timeout: Duration) -> io::Result<()> {
            let started = Instant::now();
            while !bytes.is_empty() {
                let left = timeout.saturating_sub(started.elapsed());
                if left.is_zero() {
                    return Err(io::ErrorKind::TimedOut.into());
                }
                self.0.set_write_timeout(Some(left))?;
                match self.0.write(bytes) {
                    Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                    Ok(n) => bytes = &bytes[n..],
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                    Err(e) if timed_out(&e) => return Err(io::ErrorKind::TimedOut.into()),
                    Err(e) => return Err(e),
                }
            }
            Ok(())
        }
    }
}

#[cfg(windows)]
mod platform {
    use super::ReadStatus;
    use std::fs::{File, OpenOptions};
    use std::io;
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_BROKEN_PIPE, ERROR_HANDLE_EOF, ERROR_IO_PENDING,
        ERROR_MORE_DATA, ERROR_NO_DATA, ERROR_OPERATION_ABORTED, ERROR_PIPE_NOT_CONNECTED, HANDLE,
        WAIT_OBJECT_0, WAIT_TIMEOUT,
    };
    use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile, FILE_FLAG_OVERLAPPED};
    use windows_sys::Win32::System::Threading::{CreateEventW, WaitForSingleObject};
    use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};

    pub struct Inner {
        pipe: File,
        /// Manual-reset event reused for every overlapped operation (one at a time).
        event: HANDLE,
    }

    // SAFETY: the event handle is owned by this value and only used through `&mut self`.
    unsafe impl Send for Inner {}

    impl Drop for Inner {
        fn drop(&mut self) {
            // SAFETY: created by CreateEventW in `open`, closed exactly once.
            unsafe { CloseHandle(self.event) };
        }
    }

    enum Done {
        Bytes(u32),
        TimedOut,
        Closed,
    }

    fn closed(code: u32) -> bool {
        matches!(
            code,
            ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED | ERROR_HANDLE_EOF | ERROR_NO_DATA
        )
    }

    fn millis(timeout: Duration) -> u32 {
        timeout.as_millis().clamp(1, u128::from(u32::MAX - 1)) as u32
    }

    impl Inner {
        pub fn open(endpoint: &str) -> io::Result<Self> {
            let pipe = OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(FILE_FLAG_OVERLAPPED)
                .open(endpoint)?;
            // SAFETY: plain Win32 call; null attributes and name are permitted.
            let event = unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) };
            if event.is_null() {
                return Err(io::Error::last_os_error());
            }
            Ok(Self { pipe, event })
        }

        /// Finish one started overlapped operation. The OVERLAPPED block and the caller's
        /// buffer stay alive until the kernel reports completion or confirmed cancellation,
        /// so no I/O can touch them after this returns.
        fn complete(
            &self,
            started: i32,
            overlapped: &mut OVERLAPPED,
            wait: u32,
        ) -> io::Result<Done> {
            let handle = self.pipe.as_raw_handle() as HANDLE;
            let mut transferred = 0_u32;
            // SAFETY: `overlapped` belongs to the operation just started on `handle`; all
            // pointers are valid for the duration of each call.
            unsafe {
                if started == 0 {
                    match GetLastError() {
                        ERROR_IO_PENDING => {}
                        ERROR_MORE_DATA => {
                            GetOverlappedResult(handle, overlapped, &mut transferred, 0);
                            return Ok(Done::Bytes(transferred));
                        }
                        code if closed(code) => return Ok(Done::Closed),
                        code => return Err(io::Error::from_raw_os_error(code as i32)),
                    }
                    match WaitForSingleObject(self.event, wait) {
                        WAIT_OBJECT_0 => {}
                        WAIT_TIMEOUT => {
                            CancelIoEx(handle, overlapped);
                            // Wait for the cancellation (or a racing completion) to settle.
                            if GetOverlappedResult(handle, overlapped, &mut transferred, 1) != 0 {
                                return Ok(Done::Bytes(transferred));
                            }
                            return match GetLastError() {
                                ERROR_OPERATION_ABORTED => Ok(Done::TimedOut),
                                ERROR_MORE_DATA => Ok(Done::Bytes(transferred)),
                                code if closed(code) => Ok(Done::Closed),
                                code => Err(io::Error::from_raw_os_error(code as i32)),
                            };
                        }
                        _ => return Err(io::Error::last_os_error()),
                    }
                }
                if GetOverlappedResult(handle, overlapped, &mut transferred, 0) != 0 {
                    return Ok(Done::Bytes(transferred));
                }
                match GetLastError() {
                    ERROR_MORE_DATA => Ok(Done::Bytes(transferred)),
                    code if closed(code) => Ok(Done::Closed),
                    code => Err(io::Error::from_raw_os_error(code as i32)),
                }
            }
        }

        fn overlapped(&self) -> OVERLAPPED {
            // SAFETY: OVERLAPPED is plain data; all-zero is its documented initial state.
            let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
            overlapped.hEvent = self.event;
            overlapped
        }

        pub fn read(&mut self, buffer: &mut [u8], timeout: Duration) -> io::Result<ReadStatus> {
            let mut overlapped = self.overlapped();
            let length = buffer.len().min(u32::MAX as usize) as u32;
            // SAFETY: buffer and overlapped outlive the operation (see `complete`).
            let started = unsafe {
                ReadFile(
                    self.pipe.as_raw_handle() as HANDLE,
                    buffer.as_mut_ptr(),
                    length,
                    std::ptr::null_mut(),
                    &mut overlapped,
                )
            };
            Ok(
                match self.complete(started, &mut overlapped, millis(timeout))? {
                    Done::Bytes(0) | Done::Closed => ReadStatus::Closed,
                    Done::Bytes(n) => ReadStatus::Data(n as usize),
                    Done::TimedOut => ReadStatus::TimedOut,
                },
            )
        }

        pub fn write_all(&mut self, mut bytes: &[u8], timeout: Duration) -> io::Result<()> {
            let begun = Instant::now();
            while !bytes.is_empty() {
                let left = timeout.saturating_sub(begun.elapsed());
                if left.is_zero() {
                    return Err(io::ErrorKind::TimedOut.into());
                }
                let mut overlapped = self.overlapped();
                let length = bytes.len().min(u32::MAX as usize) as u32;
                // SAFETY: bytes and overlapped outlive the operation (see `complete`).
                let started = unsafe {
                    WriteFile(
                        self.pipe.as_raw_handle() as HANDLE,
                        bytes.as_ptr(),
                        length,
                        std::ptr::null_mut(),
                        &mut overlapped,
                    )
                };
                match self.complete(started, &mut overlapped, millis(left))? {
                    Done::Bytes(0) => return Err(io::ErrorKind::WriteZero.into()),
                    Done::Bytes(n) => bytes = &bytes[n as usize..],
                    Done::TimedOut => return Err(io::ErrorKind::TimedOut.into()),
                    Done::Closed => return Err(io::ErrorKind::BrokenPipe.into()),
                }
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timed_out_wait_costs_its_timeout_and_data_costs_at_most_that() {
        let mut budget = Budget::new(Duration::from_millis(300));
        // A resume-from-suspend clock jump must not be charged beyond the requested wait.
        let long_ago = Instant::now() - Duration::from_secs(3600);
        budget.charge(Duration::from_millis(100), long_ago, false);
        assert_eq!(budget.left(), Duration::from_millis(200));
        budget.charge(Duration::from_millis(100), Instant::now(), true);
        assert_eq!(budget.left(), Duration::from_millis(100));
        budget.charge(Duration::from_millis(100), Instant::now(), false);
        assert!(budget.left() > Duration::from_millis(90));
        budget.charge(Duration::from_secs(5), Instant::now(), true);
        assert!(budget.left().is_zero());
    }

    #[cfg(unix)]
    #[test]
    fn unix_read_times_out_then_delivers_then_reports_close() {
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let mut stream = Stream::connect(path.to_str().unwrap(), Duration::from_secs(2)).unwrap();
        let (mut peer, _) = listener.accept().unwrap();
        let mut buffer = [0_u8; 8];
        let started = Instant::now();
        assert_eq!(
            stream.read(&mut buffer, Duration::from_millis(80)).unwrap(),
            ReadStatus::TimedOut
        );
        assert!(started.elapsed() >= Duration::from_millis(70));
        peer.write_all(b"abc").unwrap();
        assert_eq!(
            stream.read(&mut buffer, Duration::from_secs(2)).unwrap(),
            ReadStatus::Data(3)
        );
        drop(peer);
        assert_eq!(
            stream.read(&mut buffer, Duration::from_secs(2)).unwrap(),
            ReadStatus::Closed
        );
    }

    #[cfg(unix)]
    #[test]
    fn unix_write_to_a_peer_that_never_reads_times_out() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let mut stream = Stream::connect(path.to_str().unwrap(), Duration::from_secs(2)).unwrap();
        let _peer = listener.accept().unwrap();
        let big = vec![0_u8; 8 * 1024 * 1024];
        let error = stream
            .write_all(&big, Duration::from_millis(150))
            .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    }
}
