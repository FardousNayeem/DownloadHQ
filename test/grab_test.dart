import 'package:flutter_test/flutter_test.dart';
import 'package:downloadhq/domain/models.dart';
import 'package:downloadhq/engine/ytdlp_cli.dart';
import 'package:downloadhq/services/grab_service.dart';
import 'package:downloadhq/services/share_service.dart';

void main() {
  test('single item probe keeps page url, id prefix and video heights', () {
    const raw = '''
{"id":"293","title":"Flickermood","extractor_key":"Soundcloud","webpage_url":"https://soundcloud.com/forss/flickermood",
 "duration":213.9,"thumbnail":"t.jpg","formats":[{"vcodec":"none","height":null}]}''';
    final r = parseProbeJson(raw, 'https://soundcloud.com/forss/flickermood');
    expect(r.isPlaylist, isFalse);
    final e = r.entries.single;
    expect(e.id, 'Soundcloud:293');
    expect(e.url, 'https://soundcloud.com/forss/flickermood');
    expect(e.heights, isEmpty); // audio only
  });

  test('youtube ids stay bare and heights are sorted and unique', () {
    const raw = '''
{"id":"abc","title":"V","extractor_key":"Youtube","webpage_url":"https://www.youtube.com/watch?v=abc",
 "formats":[{"vcodec":"avc1","height":720},{"vcodec":"vp9","height":360},{"vcodec":"avc1","height":720}]}''';
    final e = parseProbeJson(raw, 'x').entries.single;
    expect(e.id, 'abc');
    expect(e.heights, [360, 720]);
  });

  test('playlist-like page lists entries with their urls', () {
    const raw = '''
{"_type":"playlist","title":"Channel","entries":[
 {"id":"a","title":"A","ie_key":"Youtube","url":"https://www.youtube.com/watch?v=a"},
 {"id":"b","title":"B","ie_key":"Youtube"}]}''';
    final r = parseProbeJson(raw, 'x');
    expect(r.isPlaylist, isTrue);
    expect(r.entries.map((e) => e.id), ['a']); // no url, can't download
  });

  test('entry file key is filesystem safe', () {
    final e = Entry(id: 'ArchiveOrg:Popeye/x?', title: '', position: 0, firstSeen: DateTime(2000));
    expect(e.fileKey, 'ArchiveOrg_Popeye_x_');
    expect(
      Entry(id: 'abc', title: '', position: 0, firstSeen: DateTime(2000)).downloadUrl,
      'https://www.youtube.com/watch?v=abc',
    );
  });

  group('worthProbing', () {
    test('skips home pages and searches', () {
      expect(worthProbing('https://m.youtube.com/'), isFalse);
      expect(worthProbing('https://www.youtube.com/results?search_query=x'), isFalse);
      expect(worthProbing('https://duckduckgo.com/?q=x'), isFalse);
      expect(worthProbing('about:blank'), isFalse);
      expect(worthProbing('https://www.google.co.uk/search?q=x'), isFalse);
      expect(worthProbing('https://m.youtube.com/feed/subscriptions'), isFalse);
      expect(worthProbing('https://music.youtube.com/search?q=x'), isFalse);
    });
    test('only a leading m. or www. is ignored', () {
      // Used to become "googlecom" and "texample" and skip or probe wrongly.
      expect(worthProbing('https://tm.google.com/watch'), isTrue);
    });
    test('probes content pages', () {
      expect(worthProbing('https://m.youtube.com/watch?v=abc'), isTrue);
      expect(worthProbing('https://soundcloud.com/forss/flickermood'), isTrue);
    });
  });

  test('friendly probe errors', () {
    expect(friendlyProbeError('Unsupported URL: https://example.com/'), 'Nothing downloadable on this page.');
    expect(
      friendlyProbeError('[vimeo] 1: The web client only works when logged-in. Use --cookies'),
      contains('signed in'),
    );
    expect(
      friendlyProbeError('[generic] x: Unable to download webpage: HTTP Error 404: Not Found'),
      'This page does not exist.',
    );
    expect(
      friendlyProbeError('Unable to download webpage: <urlopen error [Errno -3] Failed to resolve>'),
      contains('connection'),
    );
  });

  test('shared text yields its link', () {
    expect(linkIn('Great song https://youtu.be/abc?si=x'), 'https://youtu.be/abc?si=x');
    expect(linkIn('(https://example.com/a).'), 'https://example.com/a');
    expect(linkIn('no link here'), isNull);
    expect(linkIn(null), isNull);
  });
}
