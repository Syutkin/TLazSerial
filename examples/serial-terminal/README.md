# TLazSerial diagnostic terminal

A Lazarus GUI example with a dark terminal card, HEX/ASCII views, text and
binary sending, connection statistics and optional file logging. All terminal
UI and logging code stays in this example; it adds no library dependency.

Build from the repository root:

```sh
lazbuild --ws=qt6 examples/serial-terminal/serialterminal.lpi
examples/serial-terminal/.example_build/serialterminal
```

An optional device argument preselects a port, for example `COM3` or
`/dev/ttyUSB0`. Choose the port and serial format, then press **Connect**.
**Hide settings** gives more room to the exchange view.

- **HEX / ASCII view:** switch the retained exchange between byte values and
  text. ASCII view escapes control and non-ASCII bytes (`\0`, `\r`, `\n`,
  `\xFF`) so binary data remains distinguishable. RX chunks are not packets.
- **Text (UTF-8):** send text with no ending, CR, LF or CRLF. **HEX bytes:**
  send pairs such as `55 AA 00 FF` or `55AA00FF`, with no automatic ending.
  The entire input is validated before it is queued. Enter also sends.
- **Sending:** uses `WriteDataAsync` with the bounded FIFO, defaulting to
  65536 bytes and 64 operations. Each command shows its ID, outcome and actual
  byte count. The editable TX timeout defaults to 1000 ms and starts when
  the command is launched. Completion means OS acceptance, not device acknowledgement.
- **DTR / RTS on open:** choose Default, Inactive or Active before connecting.
  Settings are disabled while connected, reconnecting or cleaning up.
  Unsupported driver operations and flow-control conflicts are reported.
- **Auto reconnect:** uses the library's stable-identity matching and default
  retry settings. Closing cancels recovery; old commands are never replayed.
- **Pause view:** freezes the screen while reception, statistics and file
  logging continue. Paused entries are not replayed on resume. **Clear** only
  clears the screen, preserving counters and the file.
- **Log to file:** saves timestamped RX bytes, accepted TX requests, completion
  results and diagnostic messages. Records contain both HEX and escaped ASCII,
  independently of the selected view. File writes run in a worker with a
  bounded 1 MiB queue; an overflow or write error stops logging and reports why.
  Stop logging drains accepted records; exiting also waits for that drain.

The screen keeps at most 1000 entries and 64 KiB of retained payload, shows a
1024-byte preview per chunk and renders at most 2000 lines. Omitted bytes are
marked; the file records complete data. Statistics refresh every 250 ms; rates
use decimal KB/s and reset their baseline after reconnection. Hover over the
card for the full statistics detail, including the last error and close reason.

TX requests are labelled `TX-QUEUED`; only `TX-RESULT` reports completion and
its actual progress. Closing suppresses pending library results, recorded as
`TX-CLOSED`; their final per-command byte counts are unavailable. Statistics
can still advance during native cleanup. A file log is a diagnostic record,
not a guarantee that the remote device received the bytes.

See the [API guide](../../docs/API.md) for buffered reads, write results and
lifecycle restrictions, and [development notes](../../docs/DEVELOPMENT.md#virtual-ports)
for virtual-port setup. Physical USB identity, DTR/RTS and automatic reconnection
need suitable hardware for manual validation.
