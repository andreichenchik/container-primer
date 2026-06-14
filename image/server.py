import os
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler

# Serve the mounted workspace. SimpleHTTPRequestHandler reads each file from
# disk per request, so host edits to the workspace show up live.
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
os.chdir("/workspace")
HTTPServer(("", port), SimpleHTTPRequestHandler).serve_forever()
