""" """

from datetime import datetime
import pandas as pd
import plotly.express as px
from plotly.graph_objects import Figure
from dash import html

from src.config.settings import CATEGORY_COLORS, JOB_CATEGORIES

# region Private helper functions


def _format_salary(job: dict) -> str | None:
    salary_min = job.get("salary_min")
    salary_max = job.get("salary_max")

    if salary_min is None and salary_max is None:
        return None

    if salary_min is not None and salary_max is not None:
        salary = f"€{salary_min:,.0f}–€{salary_max:,.0f}"
    elif salary_min is not None:
        salary = f"From €{salary_min:,.0f}"
    else:
        salary = f"Up to €{salary_max:,.0f}"

    if job.get("salary_period"):
        salary += f" / {job['salary_period']}"

    return salary


def _format_location(location: dict) -> str:
    parts = [
        location.get("postal_code"),
        location.get("city"),
        location.get("region"),
        location.get("country"),
    ]

    return ", ".join(str(part) for part in parts if part)


def _format_datetime(value: str | None) -> str:
    if not value:
        return "Unknown"

    return datetime.fromisoformat(value).strftime("%d %b %Y")


# endregion


def create_job_card(job: dict) -> html.Article:
    """Create a card for one job-search result."""

    metadata = []

    if job.get("city"):
        metadata.append(html.Span(f"⌖ {job['city']}"))

    salary = _format_salary(job)

    if salary:
        metadata.append(html.Span(salary))

    return html.Article(
        [
            html.H2(job["title"], className="job-title"),
            html.P(
                job.get("company") or "Company not specified", className="job-company"
            ),
            html.Div(metadata, className="job-metadata"),
            html.Button(
                "View details",
                id={
                    "type": "job-card-button",
                    "index": job["reference_number"],
                },
                className="details-button",
            ),
        ],
        className="job-card",
    )


def create_job_details_modal_content(job: dict) -> list:
    """Create content for the Job Details modal."""
    salary = _format_salary(job)

    locations = [
        html.Li(_format_location(location)) for location in job.get("locations", [])
    ]

    content = [
        html.H2(job["title"]),
        html.P(
            job.get("company") or "Company not specified",
            className="job-company",
        ),
    ]

    if salary:
        content.append(html.P(salary))

    if locations:
        content.extend(
            [
                html.H3("Locations"),
                html.Ul(locations),
            ]
        )

    if job.get("description"):
        content.append(
            html.Div(
                [
                    html.H3("Description"),
                    html.P(job["description"]),
                ],
                className="job-description",
            )
        )

    content.append(
        html.Div(
            [
                html.H3("Freshness"),
                html.P(
                    f"First published: "
                    f"{_format_datetime(job.get('first_publication_date'))}"
                ),
                html.P(f"Last updated: " f"{_format_datetime(job.get('modified_at'))}"),
                html.P(
                    f"Republished without changes since last update: "
                    f"{job.get("unchanged_republish_count", 0)}"
                ),
            ],
            className="job-freshness",
        )
    )

    if job.get("external_url"):
        content.append(
            html.A(
                "Open job advertisement",
                href=job["external_url"],
                target="_blank",
                rel="noopener noreferrer",
                className="details-button",
            )
        )

    return content


def create_map(jobs: list[dict]) -> Figure:
    """Create a map containing the available job locations."""

    jobs_with_coordinates = [
        job
        for job in jobs
        if job.get("latitude") is not None and job.get("longitude") is not None
    ]

    if not jobs_with_coordinates:
        figure = Figure()
        figure.update_layout(
            map={
                "style": "open-street-map",
                "zoom": 4.5,
                "center": {"lat": 51.1, "lon": 10.4},
            },
            margin={"l": 0, "r": 0, "t": 0, "b": 0},
            annotations=[
                {
                    "text": "No job locations available",
                    "showarrow": False,
                }
            ],
        )
        return figure

    jobs_frame = pd.DataFrame(jobs_with_coordinates)

    jobs_frame["category"] = jobs_frame["category"].fillna("Other")
    jobs_frame.loc[
        ~jobs_frame["category"].isin(JOB_CATEGORIES),
        "category",
    ] = "Other"

    figure = px.scatter_map(
        jobs_frame,
        lat="latitude",
        lon="longitude",
        color="category",
        color_discrete_map=CATEGORY_COLORS,
        category_orders={"category": JOB_CATEGORIES},
        hover_name="title",
        hover_data={
            "company": True,
            "city": True,
            "latitude": False,
            "longitude": False,
        },
        custom_data=[
            "reference_number",
            "company",
            "city",
            "category",
        ],
        zoom=4,
        center={"lat": 51.1, "lon": 10.4},
        map_style="open-street-map",
    )

    figure.update_traces(
        marker={"size": 18},
        hovertemplate=(
            "<b>%{hovertext}</b><br>"
            "Company: %{customdata[1]}<br>"
            "City: %{customdata[2]}<br>"
            "Category: %{customdata[3]}"
            "<extra></extra>"
        ),
    )

    figure.update_layout(
        legend={
            "title": {
                "text": "<b>Categories</b>",
                "font": {"size": 13},
            },
            "x": 0.99,
            "y": 0.99,
            "xanchor": "right",
            "yanchor": "top",
            "font": {"size": 11},
            "bgcolor": "rgba(255, 255, 255, 0.85)",
            "bordercolor": "rgba(0, 0, 0, 0.12)",
            "borderwidth": 1,
            "itemsizing": "constant",
        },
        margin={"l": 0, "r": 0, "t": 0, "b": 0},
    )

    return figure
