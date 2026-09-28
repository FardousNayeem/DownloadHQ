import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../services/creator_profile.dart';
import '../widgets/common.dart';

/// Who made the app: live GitHub profile and a feedback
/// form that goes to the creator's inbox through the user's mail app.
class CreatorScreen extends StatefulWidget {
  const CreatorScreen({super.key, required this.profiles});

  final CreatorProfileService profiles;

  @override
  State<CreatorScreen> createState() => _CreatorScreenState();
}

class _CreatorScreenState extends State<CreatorScreen> {
  late Future<GithubProfile> _profile = widget.profiles.load();

  void _retry() => setState(() => _profile = widget.profiles.load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Creator'),
      ),
      body: FutureBuilder<GithubProfile>(
        future: _profile,
        builder: (context, snap) {
          final loading = snap.connectionState != ConnectionState.done;
          final profile = snap.data;
          final failed = snap.hasError;

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              Tokens.gutter,
              8,
              Tokens.gutter,
              120,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 1080,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Creator / profile section.
                    _Reveal(
                      index: 0,
                      child: _Hero(
                        profile: profile,
                      ),
                    ),

                    const SizedBox(height: 28),

                    // GitHub profile status / stats.
                    _Reveal(
                      index: 1,
                      child: failed
                          ? _Offline(
                              onRetry: _retry,
                            )
                          : _Stats(
                              profile: profile,
                              loading: loading,
                            ),
                    ),

                    const SizedBox(height: 32),

                    // Full-width feedback section.
                    const _Reveal(
                      index: 2,
                      child: _FeedbackCard(),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Future<void> _open(BuildContext context, Uri uri) async {
  final ok = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
  ).catchError((_) => false);

  if (!ok && context.mounted) {
    showMessage(
      context,
      'Could not open $uri',
    );
  }
}

/// Fades and rises into place, one block after another. Still when the
/// system asks for less motion.
class _Reveal extends StatelessWidget {
  const _Reveal({
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }

    final delay = 0.12 * index;

    return TweenAnimationBuilder<double>(
      tween: Tween(
        begin: 0,
        end: 1,
      ),
      duration: Duration(
        milliseconds: 420 + 70 * index,
      ),
      curve: Interval(
        delay / (1 + delay),
        1,
        curve: Curves.easeOutCubic,
      ),
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(
              0,
              14 * (1 - t),
            ),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.profile,
  });

  final GithubProfile? profile;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final muted = t.textTheme.bodyMedium?.copyWith(
      color: cs.onSurfaceVariant,
    );

    final location = profile?.location;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _Avatar(
              url: profile?.avatarUrl,
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Made by',
                    style: t.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    profile?.name ?? Creator.name,
                    style: t.textTheme.headlineMedium?.copyWith(
                      fontSize: 30,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      _Meta(
                        icon: PhosphorIconsRegular.githubLogo,
                        text: '@${Creator.github}',
                      ),
                      if (location != null)
                        _Meta(
                          icon: PhosphorIconsRegular.mapPin,
                          text: location,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 560,
          ),
          child: Text(
            profile?.bio ??
                'I build DownloadHQ. The code, and what I am working on next, lives on GitHub. '
                    'Bugs and ideas are welcome, the form is right here.',
            style: muted?.copyWith(
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 22),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: () => _open(
                context,
                Creator.profileUrl,
              ),
              icon: const Icon(
                PhosphorIconsBold.githubLogo,
                size: 18,
              ),
              label: const Text('Open GitHub'),
            ),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  const ClipboardData(
                    text: Creator.email,
                  ),
                );

                if (context.mounted) {
                  showMessage(
                    context,
                    'Email address copied',
                  );
                }
              },
              icon: const Icon(
                PhosphorIconsRegular.copy,
                size: 16,
              ),
              label: const Text(
                Creator.email,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    this.url,
  });

  final String? url;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final monogram = ColoredBox(
      color: cs.surfaceContainerHigh,
      child: Center(
        child: Text(
          'FN',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: cs.primary,
            letterSpacing: -1,
          ),
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(
        shape: CircleBorder(
          side: BorderSide(
            color: cs.primary,
            width: 2,
          ),
        ),
      ),
      child: ClipOval(
        child: SizedBox.square(
          dimension: 84,
          child: Image.network(
            // GitHub serves the avatar at this address even when the API is
            // rate limited.
            url ?? 'https://github.com/${Creator.github}.png?size=200',
            fit: BoxFit.cover,
            cacheWidth: 200,
            errorBuilder: (_, _, _) => monogram,
            loadingBuilder: (_, child, progress) {
              return progress == null ? child : monogram;
            },
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({
    required this.icon,
    required this.text,
  });

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color: style?.color,
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: style,
        ),
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({
    required this.profile,
    required this.loading,
  });

  final GithubProfile? profile;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: 14,
      ),
    );
  }
}

class _Offline extends StatelessWidget {
  const _Offline({
    required this.onRetry,
  });

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    return Row(
      children: [
        Icon(
          PhosphorIconsRegular.wifiSlash,
          size: 18,
          color: t.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Could not load the GitHub profile.',
            style: t.textTheme.bodySmall,
          ),
        ),
        TextButton(
          onPressed: onRetry,
          child: const Text('Try again'),
        ),
      ],
    );
  }
}

enum _Kind {
  bug(
    'Bug',
    PhosphorIconsRegular.bug,
    'What happened, and what did you expect instead?',
  ),
  idea(
    'Idea',
    PhosphorIconsRegular.lightbulb,
    'What would make DownloadHQ better for you?',
  ),
  question(
    'Question',
    PhosphorIconsRegular.question,
    'What would you like to know?',
  ),
  other(
    'Other',
    PhosphorIconsRegular.chatCircle,
    'Say anything.',
  );

  const _Kind(
    this.label,
    this.icon,
    this.hint,
  );

  final String label;
  final IconData icon;
  final String hint;
}

class _FeedbackCard extends StatefulWidget {
  const _FeedbackCard();

  @override
  State<_FeedbackCard> createState() => _FeedbackCardState();
}

class _FeedbackCardState extends State<_FeedbackCard> {
  final _message = TextEditingController();

  _Kind _kind = _Kind.bug;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final uri = feedbackMailto(
      kind: _kind.label,
      message: _message.text,
      details: null,
    );

    final ok = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);

    if (!mounted) return;

    if (ok) {
      showMessage(
        context,
        'Your mail app has the message ready. Press send there.',
      );

      setState(
        _message.clear,
      );

      return;
    }

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text(
          'No mail app found',
        ),
        content: const Text(
          'Copy the message and send it to ${Creator.email} '
          'from any email service, like Gmail in a browser.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () async {
              final text =
                  'To: ${Creator.email}\n'
                  'Subject: DownloadHQ feedback: ${_kind.label}\n\n'
                  '${_message.text}';

              await Clipboard.setData(
                ClipboardData(
                  text: text,
                ),
              );

              if (c.mounted) {
                Navigator.pop(c);
              }

              if (mounted) {
                showMessage(
                  context,
                  'Message copied',
                );
              }
            },
            child: const Text(
              'Copy message',
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final ready = _message.text.trim().isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        20,
        22,
        20,
        20,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(
          Tokens.radiusSurface,
        ),
        border: Border.all(
          color: cs.outline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                PhosphorIconsFill.paperPlaneTilt,
                color: cs.primary,
                size: 22,
              ),
              const SizedBox(width: 10),
              Text(
                'Send feedback',
                style: t.textTheme.titleLarge,
              ),
            ],
          ),

          const SizedBox(height: 6),

          Text(
            'Found a bug, or missing something? It goes straight to my inbox.',
            style: t.textTheme.bodySmall?.copyWith(
              height: 1.45,
            ),
          ),

          const SizedBox(height: 20),

          Text(
            'About',
            style: t.textTheme.labelLarge,
          ),

          const SizedBox(height: 8),

          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in _Kind.values)
                ChoiceChip(
                  avatar: Icon(
                    k.icon,
                    size: 16,
                    color: k == _kind
                        ? cs.primary
                        : cs.onSurfaceVariant,
                  ),
                  label: Text(
                    k.label,
                  ),
                  selected: k == _kind,
                  showCheckmark: false,
                  onSelected: (_) {
                    setState(
                      () => _kind = k,
                    );
                  },
                ),
            ],
          ),

          const SizedBox(height: 18),

          Text(
            'Message',
            style: t.textTheme.labelLarge,
          ),

          const SizedBox(height: 8),

          TextField(
            controller: _message,
            minLines: 5,
            maxLines: 10,
            maxLength: 4000,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: _kind.hint,
              counterText: '',
            ),
          ),

          const SizedBox(height: 18),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: ready ? _send : null,
              icon: const Icon(
                PhosphorIconsBold.paperPlaneRight,
                size: 18,
              ),
              label: const Text(
                'Send email',
              ),
            ),
          ),

          const SizedBox(height: 8),

          Center(
            child: Text(
              'Opens your mail app with this filled in',
              style: t.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}