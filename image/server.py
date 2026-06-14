import os
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler

# Serve the mounted workspace. SimpleHTTPRequestHandler reads each file from
# disk per request, so host edits to the workspace show up live.
header = os.environ.get("PRIMER_HEADER")


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        # Echo the forwarded env var as a response header when it is set.
        if header:
            self.send_header("X-Primer-Header", header)
        super().end_headers()


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
os.chdir("/workspace")
HTTPServer(("", port), Handler).serve_forever()
