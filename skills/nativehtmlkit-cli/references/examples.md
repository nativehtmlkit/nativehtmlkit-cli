# CLI examples

For CSV and structured output:

```bash
printf 'name,status\na,up\nb,down\n' | nativehtmlkit select --input-format csv --multi --output-format json
```

Cancellation is not an error: handle exit status `2`. Host errors use exit `1`, timeout `124`. Never parse stderr as selected results.
