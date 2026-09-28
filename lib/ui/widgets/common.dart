import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../domain/models.dart';

/// Local thumbnail when downloaded (works offline), network one otherwise,
/// flat placeholder when neither loads.
class EntryThumb extends StatelessWidget {
  const EntryThumb({super.key, required this.entry, this.width = 96, this.radius = 10});

  final Entry? entry;
  final double width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: cs.surfaceContainerHigh,
      child: Center(
        child: Icon(PhosphorIconsRegular.musicNotes, color: cs.onSurfaceVariant, size: width / 4),
      ),
    );
    final e = entry;
    // No existence check here: this builds several times a second on the
    // Downloads tab, and a missing file already lands in errorBuilder.
    final Widget network = e?.thumbnailUrl == null
        ? placeholder
        : Image.network(
            e!.thumbnailUrl!,
            fit: BoxFit.cover,
            cacheWidth: (width * 2).round(),
            errorBuilder: (_, _, _) => placeholder,
          );
    final Widget img = e?.thumbPath == null
        ? network
        : Image.file(
            File(e!.thumbPath!),
            fit: BoxFit.cover,
            cacheWidth: (width * 2).round(),
            errorBuilder: (_, _, _) => network,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: width, height: width * 9 / 16, child: img),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(Tokens.gutter * 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 36, color: t.colorScheme.primary),
              const SizedBox(height: 16),
              Text(title, style: t.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(body, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small rounded count, used for "new" markers.
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.label});
  final int count;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(color: cs.primary, shape: const StadiumBorder()),
      child: Text(
        label == null ? '$count' : '$count $label',
        style: TextStyle(color: cs.onPrimary, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Inline marker on entries that arrived since the last check.
class NewTag extends StatelessWidget {
  const NewTag({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: ShapeDecoration(color: cs.primary, shape: const StadiumBorder()),
      child: Text(
        'NEW',
        style: TextStyle(color: cs.onPrimary, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Circular progress with a visible track and the percentage in the middle.
/// Spins without a number while the amount of work is unknown. [center]
/// replaces the percentage (e.g. a cancel glyph).
class ProgressRing extends StatelessWidget {
  const ProgressRing({super.key, this.value, this.size = 44, this.center});

  final double? value;
  final double size;
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = value;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CircularProgressIndicator(
            value: v,
            strokeWidth: size / 12,
            strokeCap: StrokeCap.round,
            backgroundColor: cs.outline,
          ),
          Center(
            child:
                center ??
                (v == null
                    ? const SizedBox.shrink()
                    : Text(
                        '${(v * 100).floor()}%',
                        style: TextStyle(
                          fontSize: size * 0.26,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: cs.onSurface,
                        ),
                      )),
          ),
        ],
      ),
    );
  }
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Search box for lists. Ctrl+F focuses it on desktop (see [searchShortcuts]), Esc clears it.
class SearchField extends StatefulWidget {
  const SearchField({super.key, required this.hint, required this.onChanged, this.focusNode});

  final String hint;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  final _c = TextEditingController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();

  @override
  void dispose() {
    _c.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _clear() {
    _c.clear();
    widget.onChanged('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clear},
      child: TextField(
        controller: _c,
        focusNode: _focus,
        textInputAction: TextInputAction.search,
        onChanged: (v) {
          widget.onChanged(v);
          setState(() {});
        },
        onTapOutside: (_) => _focus.unfocus(),
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hint,
          prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, size: 18, color: cs.onSurfaceVariant),
          suffixIcon: _c.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  onPressed: _clear,
                  icon: Icon(PhosphorIconsBold.x, size: 14, color: cs.onSurfaceVariant),
                ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }
}

/// Shortcuts that focus a search box: Ctrl+F and Cmd+F.
Map<ShortcutActivator, VoidCallback> searchShortcuts(FocusNode node) => {
  const SingleActivator(LogicalKeyboardKey.keyF, control: true): node.requestFocus,
  const SingleActivator(LogicalKeyboardKey.keyF, meta: true): node.requestFocus,
};

/// Every word of [query] appears in one of [fields], ignoring case.
bool matchesQuery(String query, Iterable<String?> fields) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return true;
  final hay = fields.whereType<String>().join(' ').toLowerCase();
  return words.every(hay.contains);
}
