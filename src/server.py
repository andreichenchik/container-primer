import os
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler

# Serve files from the sibling `public/` directory. SimpleHTTPRequestHandler
# reads each file from disk per request, so host edits to public/ show up live.
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
os.chdir(os.path.join(os.path.dirname(__file__), "public"))
HTTPServer(("", port), SimpleHTTPRequestHandler).serve_forever()
