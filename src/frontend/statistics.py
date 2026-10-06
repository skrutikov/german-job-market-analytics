""" """

import requests

import pandas as pd
import plotly.express as px
from dash import dcc, html

from src.config.settings import CATEGORY_COLORS, FASTAPI_URL

# region Private helper functions


def _get_statistics() -> tuple[dict, list, list, dict, list, list]:
    overview = requests.get(
        f"{FASTAPI_URL}/statistics/overview",
        timeout=10,
    )
    overview.raise_for_status()

    companies = requests.get(
        f"{FASTAPI_URL}/statistics/companies",
        params={"limit": 10},
        timeout=10,
    )
    companies.raise_for_status()

    locations = requests.get(
        f"{FASTAPI_URL}/statistics/locations",
        params={"limit": 10},
        timeout=10,
    )
    locations.raise_for_status()

    home_office = requests.get(
        f"{FASTAPI_URL}/statistics/home-office",
        timeout=10,
    )
    home_office.raise_for_status()

    categories = requests.get(
        f"{FASTAPI_URL}/statistics/categories",
        timeout=10,
    )
    categories.raise_for_status()

    publication_trends = requests.get(
        f"{FASTAPI_URL}/statistics/publication-trends",
        timeout=10,
    )
    publication_trends.raise_for_status()

    return (
        overview.json(),
        companies.json(),
        locations.json(),
        home_office.json(),
        categories.json(),
        publication_trends.json(),
    )


# endregion


def create_statistics_content() -> tuple[html.Div, list[dcc.Graph]]:
    overview, companies, locations, home_office, categories, publication_trends = (
        _get_statistics()
    )

    overview_cards = html.Div(
        [
            html.Div(
                [
                    html.H3("Jobs"),
                    html.P(overview["total_jobs"]),
                ],
                className="statistics-card",
            ),
            html.Div(
                [
                    html.H3("Companies"),
                    html.P(overview["total_companies"]),
                ],
                className="statistics-card",
            ),
            html.Div(
                [
                    html.H3("Locations"),
                    html.P(overview["total_locations"]),
                ],
                className="statistics-card",
            ),
            html.Div(
                [
                    html.H3("Period"),
                    html.P(
                        f"{overview['earliest_publication_date']} – "
                        f"{overview['latest_publication_date']}"
                    ),
                ],
                className="statistics-card",
            ),
        ],
        className="statistics-overview",
    )

    companies_df = pd.DataFrame(companies)
    companies_figure = px.bar(
        companies_df,
        x="job_count",
        y="company",
        orientation="h",
        title="Top companies",
    )

    locations_df = pd.DataFrame(locations)
    locations_figure = px.bar(
        locations_df,
        x="job_count",
        y="city",
        orientation="h",
        title="Top locations",
    )

    home_office_df = pd.DataFrame(
        {
            "status": ["Possible", "Not possible", "Unknown"],
            "count": [
                home_office["possible"],
                home_office["not_possible"],
                home_office["unknown"],
            ],
        }
    )
    home_office_figure = px.pie(
        home_office_df,
        names="status",
        values="count",
        hole=0.5,
        title="Home office",
    )

    categories_df = pd.DataFrame(categories).sort_values("job_count")
    categories_figure = px.bar(
        categories_df,
        x="job_count",
        y="category",
        color="category",
        color_discrete_map=CATEGORY_COLORS,
        orientation="h",
        title="Jobs by category",
    )
    categories_figure.update_layout(
        showlegend=False,
        xaxis_title="Jobs",
        yaxis_title=None,
    )

    publication_trends_df = pd.DataFrame(publication_trends)
    publication_trends_figure = px.line(
        publication_trends_df,
        x="month",
        y="job_count",
        markers=True,
        title="Jobs by first publication month",
        labels={
            "month": "First publication month",
            "job_count": "Currently stored jobs",
        },
    )
    publication_trends_figure.update_layout(
        hovermode="x unified",
    )
    publication_trends_figure.update_xaxes(
        tickformat="%b %Y",
        rangeslider_visible=True,
        rangeselector={
            "buttons": [
                {
                    "count": 3,
                    "label": "3m",
                    "step": "month",
                    "stepmode": "backward",
                },
                {
                    "count": 6,
                    "label": "6m",
                    "step": "month",
                    "stepmode": "backward",
                },
                {
                    "count": 1,
                    "label": "1y",
                    "step": "year",
                    "stepmode": "backward",
                },
                {
                    "label": "All",
                    "step": "all",
                },
            ]
        },
    )

    return overview_cards, [
        dcc.Graph(figure=publication_trends_figure),
        dcc.Graph(figure=companies_figure),
        dcc.Graph(figure=locations_figure),
        dcc.Graph(figure=home_office_figure),
        dcc.Graph(figure=categories_figure),
    ]
