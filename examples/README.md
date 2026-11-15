# CLI examples

`sample-form.html` is a trusted form fragment for `nhk form`:

```bash
nhk form --html examples/sample-form.html     # Submit -> {"entries":[...]} on stdout
```

It is shipped in release archives under `examples/` and is used by the GUI qualification
harnesses (case s08). The commands in `../docs/CLI-Spec/examples/` are draft research, not
executable documentation.
