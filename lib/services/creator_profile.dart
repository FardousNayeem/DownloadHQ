import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Who made DownloadHQ, and how to reach them.
abstract final class Creator {
  static const name = 'Fardous Nayeem';
  static const github = 'FardousNayeem';
  static const email = 'fardousnayeem34@gmail.com';
  static final profileUrl = Uri.parse('https://github.com/$github');
}

class GithubRepo {
  const GithubRepo({required this.name, required this.url, this.description, this.language, this.stars = 0});
  final String name;
  final String url;
  final String? description;
  final String? language;
  final int stars;
}

class GithubProfile {
  const GithubProfile({
    this.name,
    this.bio,
    this.location,
    this.avatarUrl,
    this.publicRepos,
    this.followers,
    this.following,
    this.repos = const [],
  });

  final String? name;
  final String? bio;
  final String? location;
  final String? avatarUrl;
  final int? publicRepos;
  final int? followers;
  final int? following;
  final List<GithubRepo> repos;
}

/// Reads the creator's public GitHub profile (no token; 60 requests an
/// hour per IP, plenty for a page opened by hand). Remembered for the
/// session so switching tabs does not ask again.
class CreatorProfileService {
  Future<GithubProfile>? _cached;

  Future<GithubProfile> load() => _cached ??= _fetch().catchError((Object e) {
    _cached = null; // try again next visit
    throw e;
  });

  Future<GithubProfile> _fetch() async {
    final user = await _getJson('https://api.github.com/users/${Creator.github}') as Map;
    List repos = const [];
    try {
      repos = await _getJson('https://api.github.com/users/${Creator.github}/repos?sort=pushed&per_page=12') as List;
    } catch (e) {
      debugPrint('DownloadHQ: repos: $e');
    }
    return parseGithubProfile(user.cast<String, dynamic>(), repos);
  }

  static Future<Object?> _getJson(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'DownloadHQ');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}');
      return jsonDecode(body);
    } finally {
      client.close();
    }
  }
}

/// Own repositories (not forks), most recently worked on first, up to four.
@visibleForTesting
GithubProfile parseGithubProfile(Map<String, dynamic> u, List repos) {
  String? str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  return GithubProfile(
    name: str(u['name']),
    bio: str(u['bio']),
    location: str(u['location']),
    avatarUrl: str(u['avatar_url']),
    publicRepos: u['public_repos'] as int?,
    followers: u['followers'] as int?,
    following: u['following'] as int?,
    repos: [
      for (final r in repos.whereType<Map>())
        if (r['fork'] != true && r['name'] is String && r['html_url'] is String)
          GithubRepo(
            name: r['name'] as String,
            url: r['html_url'] as String,
            description: str(r['description']),
            language: str(r['language']),
            stars: r['stargazers_count'] as int? ?? 0,
          ),
    ].take(4).toList(),
  );
}

/// The feedback email: subject says what kind, body carries the message and,
/// when allowed, what it runs on (helps reproduce bugs).
Uri feedbackMailto({required String kind, required String message, String? details}) {
  final body = [message.trim(), if (details != null) '\n--\n$details'].join('\n');
  // mailto wants %20, not the + that Uri.queryParameters would write.
  final q = 'subject=${Uri.encodeComponent('DownloadHQ feedback: $kind')}&body=${Uri.encodeComponent(body)}';
  return Uri.parse('mailto:${Creator.email}?$q');
}

String deviceDetails() =>
    'Sent from DownloadHQ\n${Platform.operatingSystem} ${Platform.operatingSystemVersion}\nLocale: ${Platform.localeName}';
