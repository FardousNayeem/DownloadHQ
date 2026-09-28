import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/bootstrap.dart';
import '../../app/theme.dart';
import '../../services/download_queue.dart';
import '../format.dart';
import '../widgets/common.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.queue, s.library]),
      builder: (context, _) {
        final jobs = s.queue.jobs;
        final failed = jobs.where((j) => j.state == JobState.failed).length;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Downloads'),
            actions: [
              if (failed > 0) TextButton(onPressed: s.queue.retryAllFailed, child: Text('Retry $failed failed')),
              const SizedBox(width: 8),
            ],
          ),
          body: jobs.isEmpty
              ? const EmptyState(
                  icon: PhosphorIconsRegular.downloadSimple,
                  title: 'Nothing downloading',
                  body: 'Pick videos in a playlist and tap Download. Finished files show up in their playlist.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: jobs.length,
                  itemBuilder: (context, i) => _JobRow(job: jobs[i]),
                ),
        );
      },
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job});
  final DownloadJob job;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final entry = s.library.byId(job.playlistId)?.entry(job.entryId);
    final pr = job.progress;
    final status = switch (job.state) {
      JobState.queued => 'Waiting',
      JobState.failed => job.error ?? 'Failed',
      JobState.running when job.note != null => job.note!,
      JobState.running => [
        if (pr?.fraction != null) '${(pr!.fraction! * 100).round()}%',
        if (pr?.speedBps != null) formatSpeed(pr!.speedBps),
        if (pr?.eta != null) '${formatDuration(pr!.eta)} left',
      ].join('   '),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter, vertical: 8),
      child: Row(
        children: [
          EntryThumb(entry: entry, width: 80),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge),
                const SizedBox(height: 6),
                if (job.state == JobState.running && job.note == null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(value: pr?.fraction, minHeight: 3),
                  ),
                const SizedBox(height: 6),
                Text(
                  status.isEmpty ? 'Starting' : status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: job.state == JobState.failed ? t.colorScheme.error : null,
                  ),
                ),
              ],
            ),
          ),
          if (job.state == JobState.failed)
            IconButton(
              tooltip: 'Retry',
              onPressed: () => s.queue.retry(job),
              icon: const Icon(PhosphorIconsRegular.arrowCounterClockwise),
            ),
          IconButton(
            tooltip: job.state == JobState.failed ? 'Dismiss' : 'Cancel',
            onPressed: () => s.queue.cancel(job),
            icon: const Icon(PhosphorIconsRegular.x),
          ),
        ],
      ),
    );
  }
}
