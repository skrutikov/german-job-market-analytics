#!/bin/sh

#If any command fails, stop the script immediately.
set -e

echo "Starting FastAPI on port 8000..."
# 0.0.0.0 tells Uvicorn to listen on all network interfaces.
# Without this, it would listen only on 127.0.0.1 inside the container,
# and Docker could not forward requests from the browser.
# "&" runs Uvicorn in the background so the script can continue.
python -m uvicorn job_market.backend.main:api \
    --host 0.0.0.0 \
    --port 8000 &

# Store the process ID of the FastAPI server in a variable so it can be killed later.
API_PID=$!

# If this script exits for any reason, kill the FastAPI server (like finally in bash).
trap 'kill "$API_PID"' INT TERM EXIT

echo "Starting Dash on port 8050..."
python -m job_market.frontend.app