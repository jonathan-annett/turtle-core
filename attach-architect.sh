#!/bin/bash
# Convenience wrapper. Use 'exec' so signals reach the container cleanly.
exec docker compose attach architect
