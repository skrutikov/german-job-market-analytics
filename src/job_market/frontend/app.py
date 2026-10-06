"""Dash frontend for the Job Market application."""

from pathlib import Path
from dash import Dash

from job_market.config.settings import DASH_DEBUG, FRONTEND_PORT
from job_market.frontend.callbacks import register_callbacks
from job_market.frontend.layouts import create_layout

ASSETS_DIRECTORY = Path(__file__).parent / "assets"

app = Dash(
    __name__,
    assets_folder=str(ASSETS_DIRECTORY),
    title="Job Market",
)

app.layout = create_layout()
register_callbacks(app)

if __name__ == "__main__":
    # 0.0.0.0 tells Uvicorn to listen on all network interfaces.
    # Without this, it would listen only on 127.0.0.1 inside the container,
    # and Docker could not forward requests from the browser.
    app.run(
        host="0.0.0.0",
        port=FRONTEND_PORT,
        debug=DASH_DEBUG,
    )
