import re

from src.config.settings import CATEGORY_KEYWORDS


def _contains_keyword(text: str, keyword: str) -> bool:
    if len(keyword) <= 3:
        return (
            re.search(
                rf"(?<!\w){re.escape(keyword)}(?!\w)",
                text,
            )
            is not None
        )

    return keyword in text


def classify_job(
    title: str | None,
    occupation: str | None,
) -> str:
    text = " ".join(
        value.strip().lower()
        for value in (title, occupation)
        if value and value.strip()
    )

    for category, keywords in CATEGORY_KEYWORDS.items():
        if any(_contains_keyword(text, keyword) for keyword in keywords):
            return category

    return "Other"
