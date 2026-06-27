from g2i_route_sync.jsonutil import json_get_ci, normalize_key


def test_normalize_key_strips_case_and_separators():
    assert normalize_key("Road-Book ID") == "roadbookid"
    assert normalize_key("courseName") == "coursename"


def test_json_get_ci_matches_case_insensitively():
    container = {"CourseName": "Morning Ride"}
    assert json_get_ci(container, "coursename") == "Morning Ride"
    assert json_get_ci(container, "COURSE_NAME") == "Morning Ride"


def test_json_get_ci_returns_default_for_missing_or_non_dict():
    assert json_get_ci({"a": 1}, "b", default=42) == 42
    assert json_get_ci(["not", "a", "dict"], "a", default="x") == "x"
    assert json_get_ci(None, "a") is None


def test_json_get_ci_first_match_wins():
    container = {"code": 0, "Code": 1}
    assert json_get_ci(container, "code") == 0
