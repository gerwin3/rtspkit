# `rtspkit`

Toolkit for inspecting RTSP streams.

* `rtspq`: Query RTSP stream information.

## `rtspq`

Query RTSP stream information.

### Usage

```
rtspq input1 [input2 ...] [-j|--json] [-c|--csv]
```

* `input1`, `input2`, etc.: RTSP URIs to query for stream information.
* `-j`, `--json`: Present stream information in JSON format.
* `-c`, `--csv`: Present stream information in CSV format.

If no output format is selected a table is printed.

### Examples

* Print the usage message:

  ```bash
  rtspq
  ```

* Query information for a single stream and print a table:

  ```bash
  rtspq 'rtsp://10.0.0.1/stream/0'
  ```

  Output:

  ```
  index  | codec  | profile | width  | height | fps   
  ------ | ------ | ------- | ------ | ------ | ------
  0      | h265   | main    | 1920   | 1080   | 30.00 
  ```

* Query information for multiple streams and print as JSON:

  ```bash
  rtspq 'rtsp://nvr-a/0' 'rtsp://nvr-b0' 'rtsp://nvr-a/1' --json
  ```

  Output:

  ```json
  [{"index": "0","codec": "h264","profile": "main","width": 1920,"height": 1080,"frame_rate": 30.00},{"index": "1","codec": "h264","profile": "main","width": 1920,"height": 1080,"frame_rate": 30.00}]
  ```

* Provide credentials and print as CSV:

  ```bash
  rtspq 'rtsp://user:pass@192.168.1.100/live' --csv
  ```

  Output:

  ```csv
  0,h264,high,1280,720,24.00 
  ```

### Output

The output contains the following fields:

* `index`: Index of input stream. Use this to cross-reference the output to the original input stream.
* `codec`: The video codec: Either H.264 (h264) or H.265 (h265). Other codecs are not supported.
* `profile`: The encoding profile, such as baseline, main or high. For H.265 if the stream uses the Format Range Extensions (4) the reported profile will be rext.
* `width`/`height`: Display dimensions of the stream in pixels.
* `frame_rate`: The reported frame rate. If the stream SPS contains VUI with timing information, rtspq will use this info to determine frame rate. If not, it will try and estimate the frame rate by probing the stream and counting frame deltas.

If a stream fails and information cannot be queried it will not be present in the output. Instead an error message with more information is printed to stderr.
