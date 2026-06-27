import 'package:g2i_route_sync/json_util.dart';
import 'package:test/test.dart';

void main() {
  test('normalizeKey strips case and separators', () {
    expect(normalizeKey('Road-Book ID'), 'roadbookid');
    expect(normalizeKey('courseName'), 'coursename');
  });

  test('jsonGetCi matches case insensitively', () {
    final container = {'CourseName': 'Morning Ride'};
    expect(jsonGetCi(container, 'coursename'), 'Morning Ride');
    expect(jsonGetCi(container, 'COURSE_NAME'), 'Morning Ride');
  });

  test('jsonGetCi returns default for missing or non-dict', () {
    expect(jsonGetCi({'a': 1}, 'b', 42), 42);
    expect(jsonGetCi(['not', 'a', 'dict'], 'a', 'x'), 'x');
    expect(jsonGetCi(null, 'a'), isNull);
  });

  test('jsonGetCi first match wins', () {
    final container = {'code': 0, 'Code': 1};
    expect(jsonGetCi(container, 'code'), 0);
  });
}
