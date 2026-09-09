""" """

import requests

from dash import ALL, Dash, Input, Output, State, ctx, html, no_update

from src.config.settings import FASTAPI_URL, JOB_ANY_CATEGORY_DROPDOWN_VALUE, JOBS_PAGE_SIZE
from src.dashboard.jobs import (
    create_job_card,
    create_job_details_modal_content,
    create_map,
)
from src.dashboard.statistics import create_statistics_content


def register_callbacks(app: Dash):

    @app.callback(
        Output("find-jobs-page", "style"),
        Output("statistics-page", "style"),
        Output("find-jobs-tab", "className"),
        Output("statistics-tab", "className"),
        Output("statistics-overview-content", "children"),
        Output("statistics-content", "children"),
        Input("find-jobs-tab", "n_clicks"),
        Input("statistics-tab", "n_clicks"),
    )
    def switch_tab(find_jobs_clicks, statistics_clicks):
        if ctx.triggered_id == "statistics-tab":
            try:
                overview, statistics = create_statistics_content()
            except requests.RequestException:
                overview = []
                statistics = [
                    html.Div(
                        [
                            html.H3("Statistics unavailable"),
                            html.P(
                                "The statistics API is currently unavailable. "
                                "Please try again later."
                            ),
                        ],
                        className="statistics-error",
                    )
                ]

            return (
                {"display": "none"},
                {"display": "block"},
                "navigation-tab",
                "navigation-tab active",
                overview,
                statistics,
            )

        return (
            {"display": "block"},
            {"display": "none"},
            "navigation-tab active",
            "navigation-tab",
            no_update,
            no_update,
        )

    @app.callback(
        Output("job-list", "children"),
        Output("job-map", "figure"),
        Output("current-page", "data"),
        Output("page-number", "children"),
        Output("previous-page-button", "disabled"),
        Output("next-page-button", "disabled"),
        Input("search-button", "n_clicks"),
        Input("previous-page-button", "n_clicks"),
        Input("next-page-button", "n_clicks"),
        State("current-page", "data"),
        State("keyword-input", "value"),
        State("location-input", "value"),
        State("company-input", "value"),
        State("category-input", "value"),
    )
    def search_jobs(
        search_clicks: int | None,
        previous_clicks: int | None,
        next_clicks: int | None,
        current_page: int,
        keyword: str | None,
        city: str | None,
        company: str | None,
        category: str,
    ):
        """Retrieve jobs from FastAPI and update the results."""

        if ctx.triggered_id == "search-button":
            current_page = 1
        elif ctx.triggered_id == "previous-page-button":
            current_page = max(1, current_page - 1)
        elif ctx.triggered_id == "next-page-button":
            current_page += 1

        offset = (current_page - 1) * JOBS_PAGE_SIZE

        parameters: dict[str, str | int] = {
            "limit": JOBS_PAGE_SIZE + 1,
            "offset": offset,
        }

        if keyword:
            parameters["keyword"] = keyword.strip()

        if city:
            parameters["city"] = city.strip()

        if company:
            parameters["company"] = company.strip()

        if category != JOB_ANY_CATEGORY_DROPDOWN_VALUE:
            parameters["category"] = category

        try:
            response = requests.get(
                f"{FASTAPI_URL}/jobs",
                params=parameters,
                timeout=10,
            )
            response.raise_for_status()
        except requests.RequestException:
            message = html.P(
                "The job API is currently unavailable.",
                className="error-message",
            )
            return (
                [message],
                create_map([]),
                current_page,
                f"Page {current_page}",
                current_page == 1,
                True,
            )

        jobs = response.json()

        has_next_page = len(jobs) > JOBS_PAGE_SIZE
        jobs = jobs[:JOBS_PAGE_SIZE]

        previous_disabled = current_page == 1
        next_disabled = not has_next_page

        if not jobs:
            message = html.P(
                "No matching jobs were found.",
                className="empty-message",
            )
            return (
                [message],
                create_map([]),
                current_page,
                f"Page {current_page}",
                current_page == 1,
                True,
            )

        cards = [create_job_card(job) for job in jobs]

        return (
            cards,
            create_map(jobs),
            current_page,
            f"Page {current_page}",
            previous_disabled,
            next_disabled,
        )

    @app.callback(
        Output("job-modal-overlay", "className"),
        Output("job-modal-content", "children"),
        Input(
            {
                "type": "job-card-button",
                "index": ALL,
            },
            "n_clicks",
        ),
        Input("job-map", "clickData"),
        Input("close-job-modal", "n_clicks"),
        prevent_initial_call=True,
    )
    def toggle_job_modal(
        job_clicks,
        map_click,
        close_clicks,
    ):
        triggered_id = ctx.triggered_id

        if triggered_id == "close-job-modal":
            return "modal-overlay", []

        if triggered_id == "job-map":
            reference_number = map_click["points"][0]["customdata"][0]

        elif isinstance(triggered_id, dict):
            if not any(job_clicks):
                return no_update, no_update

            reference_number = triggered_id["index"]

        else:
            return no_update, no_update

        try:
            response = requests.get(
                f"{FASTAPI_URL}/jobs/{reference_number}",
                timeout=10,
            )
            response.raise_for_status()
        except requests.RequestException:
            return (
                "modal-overlay open",
                html.P("The job details could not be loaded."),
            )

        job = response.json()

        return (
            "modal-overlay open",
            create_job_details_modal_content(job),
        )
