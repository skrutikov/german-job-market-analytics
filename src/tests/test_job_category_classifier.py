# Run it with
#   pytest src/tests/test_job_category_classifier.py
import pytest

from src.data.job_category_classifier import classify_job


@pytest.mark.parametrize(
    ("title", "occupation", "expected"),
    [
        ("Senior Data Engineer", None, "Data Engineering"),
        ("Machine Learning Engineer", None, "AI / Machine Learning"),
        ("Data Analyst", None, "Data Analysis"),
        ("Python Backend Developer", None, "Backend Development"),
        ("Cloud Engineer", None, "Cloud / DevOps"),
        ("Office Manager", None, "Other"),
        (None, None, "Other"),
    ],
)
def test_classify_job(
    title: str | None,
    occupation: str | None,
    expected: str,
) -> None:
    """Verify that representative job titles map to the expected categories."""
    assert classify_job(title, occupation) == expected


def test_short_keyword_is_not_matched_inside_word() -> None:
    """Verify that short keywords do not match accidentally inside larger words."""
    assert (
        classify_job(
            "Verstärkung für unsere Softwareabteilung",
            None,
        )
        != "Cloud / DevOps"
    )


def test_ai_category_has_priority_over_backend() -> None:
    """Verify that AI/ML takes priority when a title also matches Backend."""
    assert (
        classify_job(
            "Backend Developer for Machine Learning",
            None,
        )
        == "AI / Machine Learning"
    )
