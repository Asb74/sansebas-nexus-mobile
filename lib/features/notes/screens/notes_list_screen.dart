import 'package:flutter/material.dart';

import '../models/mobile_note.dart';
import '../services/firebase_sync_service.dart';

class NotesListScreen extends StatelessWidget {
  const NotesListScreen({super.key, FirebaseSyncService? firebaseSyncService})
      : _firebaseSyncService = firebaseSyncService;

  final FirebaseSyncService? _firebaseSyncService;

  @override
  Widget build(BuildContext context) {
    final firebaseSyncService = _firebaseSyncService ?? FirebaseSyncService();
    final uid = firebaseSyncService.currentUserId;

    return Scaffold(
      appBar: AppBar(title: const Text('Lista de notas')),
      body: uid == null || uid.isEmpty
          ? const Center(child: Text('Inicia sesión para ver tus notas.'))
          : StreamBuilder<List<MobileNote>>(
              stream: firebaseSyncService.watchUserNotes(uid),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  debugPrint('Error exacto listando notas: ${snapshot.error}');
                  return const Center(
                    child: Text('No se pudieron cargar las notas.'),
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final notes = snapshot.data ?? const <MobileNote>[];
                if (notes.isEmpty) {
                  return const Center(child: Text('Todavía no hay notas guardadas.'));
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: notes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    return Card(
                      child: ListTile(
                        title: Text(note.title),
                        subtitle: Text(
                          '${note.area} · ${note.topic} · ${note.type}\n${_formatDate(note.createdAt)} · ${note.syncStatus.value}',
                        ),
                        isThreeLine: true,
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
