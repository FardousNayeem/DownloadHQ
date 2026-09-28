import 'package:downloadhq/services/creator_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profile keeps own repositories only, four at most', () {
    final p = parseGithubProfile(
      {'name': ' Fardous ', 'bio': '', 'public_repos': 9, 'followers': 3, 'following': 1},
      [
        {'name': 'fork', 'html_url': 'u', 'fork': true},
        for (var i = 0; i < 6; i++) {'name': 'r$i', 'html_url': 'u$i', 'stargazers_count': i, 'language': 'Dart'},
      ],
    );
    expect(p.name, 'Fardous');
    expect(p.bio, isNull);
    expect(p.publicRepos, 9);
    expect(p.repos.map((r) => r.name), ['r0', 'r1', 'r2', 'r3']);
  });

  test('feedback link spells spaces as %20 and carries the details', () {
    final u = feedbackMailto(kind: 'Bug', message: 'It broke & stopped', details: 'linux 6');
    final s = u.toString();
    expect(s, startsWith('mailto:fardousnayeem34@gmail.com?subject=DownloadHQ%20feedback%3A%20Bug&body='));
    expect(s, isNot(contains('+')));
    expect(Uri.decodeComponent(s.split('body=').last), 'It broke & stopped\n\n--\nlinux 6');
  });
}
