"""Drive the fake Deck locally so two guest kernels never cache the same fixture file."""
import socketserver
import time
from pathlib import Path

fixture = Path("/run/fake-deck/input")
applied = fixture.with_suffix(".applied")


class Control(socketserver.StreamRequestHandler):
    def handle(self):
        while report := self.rfile.read(64):
            if len(report) != 64:
                return
            # A new token distinguishes even identical consecutive physical samples.
            token = (int(applied.read_text()) + 1) % 256 if applied.exists() else 1
            temporary = fixture.with_suffix(".new")
            temporary.write_bytes(report[:63] + bytes([token]))
            temporary.replace(fixture)
            deadline = time.monotonic() + 5
            while not applied.exists() or applied.read_text() != str(token):
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"fake Deck did not apply sample {token}")
                time.sleep(0.01)
            self.wfile.write(b"+")


with socketserver.TCPServer(("", 3245), Control) as server:
    server.serve_forever()
