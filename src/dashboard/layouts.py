from dash import dcc, html

from src.config.settings import (
    JOB_ANY_CATEGORY_DROPDOWN_LABEL,
    JOB_ANY_CATEGORY_DROPDOWN_VALUE,
    JOB_CATEGORIES,
)
from src.dashboard.jobs import create_map

# region Private helper functions


def _create_header() -> html.Header:
    return html.Header(
        [
            html.A(
                [
                    html.Div("J", className="brand-icon"),
                    html.Span("jobmarket"),
                ],
                href="/",
                className="brand",
            ),
            html.Nav(
                [
                    html.Button(
                        "Find jobs",
                        id="find-jobs-tab",
                        className="navigation-tab active",
                    ),
                    html.Button(
                        "Statistics",
                        id="statistics-tab",
                        className="navigation-tab",
                    ),
                    html.Button(
                        "About",
                        id="about-tab",
                        className="navigation-tab",
                    ),
                ],
                className="navigation",
            ),
        ],
        className="page-header",
    )


def _create_find_jobs_page() -> html.Div:
    return html.Div(
        id="find-jobs-page",
        children=[
            html.Section(
                [
                    html.P(
                        "Explore jobs from companies across Germany.",
                        className="tab-subtitle",
                    ),
                    html.Div(
                        [
                            html.Div(
                                [
                                    html.Label("What"),
                                    dcc.Input(
                                        id="keyword-input",
                                        type="text",
                                        placeholder="Job title or keyword",
                                    ),
                                ],
                                className="search-field",
                            ),
                            html.Div(
                                [
                                    html.Label("Where"),
                                    dcc.Input(
                                        id="location-input",
                                        type="text",
                                        placeholder="City",
                                    ),
                                ],
                                className="search-field",
                            ),
                            html.Div(
                                [
                                    html.Label("Company"),
                                    dcc.Input(
                                        id="company-input",
                                        type="text",
                                        placeholder="Any company",
                                    ),
                                ],
                                className="search-field",
                            ),
                            html.Div(
                                [
                                    html.Label("Category"),
                                    dcc.Dropdown(
                                        id="category-input",
                                        options=[
                                            {
                                                "label": JOB_ANY_CATEGORY_DROPDOWN_LABEL,
                                                "value": JOB_ANY_CATEGORY_DROPDOWN_VALUE,
                                            },
                                            *[
                                                {"label": category, "value": category}
                                                for category in JOB_CATEGORIES
                                            ],
                                        ],
                                        value=JOB_ANY_CATEGORY_DROPDOWN_VALUE,
                                        clearable=False,
                                        searchable=False,
                                    ),
                                ],
                                className="search-field",
                            ),
                            html.Button(
                                "Search",
                                id="search-button",
                                className="search-button",
                            ),
                        ],
                        className="search-panel",
                    ),
                ],
                className="tab-header",
            ),
            html.Section(
                [
                    html.Div(
                        [
                            html.Div(
                                [
                                    html.Div(
                                        id="job-list",
                                        className="job-list",
                                    ),
                                    html.Div(
                                        [
                                            html.Button(
                                                "‹",
                                                id="previous-page-button",
                                                disabled=True,
                                            ),
                                            html.Span(
                                                "Page 1",
                                                id="page-number",
                                            ),
                                            html.Button(
                                                "›",
                                                id="next-page-button",
                                            ),
                                        ],
                                        className="pagination",
                                    ),
                                ],
                                className="results-column",
                            ),
                            html.Div(
                                dcc.Graph(
                                    id="job-map",
                                    figure=create_map([]),
                                    config={
                                        "displayModeBar": False,
                                        "scrollZoom": True,
                                    },
                                    className="job-map",
                                ),
                                className="map-column",
                            ),
                        ],
                        className="search-results-content-grid",
                    ),
                ],
                className="search-results-section",
            ),
        ],
    )


def _create_statistics_page() -> html.Div:
    return html.Div(
        id="statistics-page",
        children=[
            html.Section(
                [
                    html.P(
                        "Overview of the collected job market data.",
                        className="tab-subtitle",
                    ),
                    html.Div(
                        id="statistics-overview-content",
                    ),
                ],
                className="tab-header",
            ),
            html.Div(
                id="statistics-content",
                className="statistics-content",
            ),
        ],
        style={"display": "none"},
    )


def _create_job_details_modal() -> html.Div:
    return html.Div(
        [
            html.Div(
                [
                    html.Button(
                        "×",
                        id="close-job-modal",
                        className="modal-close-button",
                    ),
                    html.Div(id="job-modal-content"),
                ],
                className="job-modal",
            ),
        ],
        id="job-modal-overlay",
        className="modal-overlay",
    )


# endregion


def create_layout() -> html.Div:
    """Create the layout of the dashboard."""
    return html.Div(
        [
            dcc.Store(
                id="current-page",
                data=1,
            ),
            _create_header(),
            html.Main(
                [
                    _create_find_jobs_page(),
                    _create_statistics_page(),
                ]
            ),
            _create_job_details_modal(),
        ],
        className="page",
    )
