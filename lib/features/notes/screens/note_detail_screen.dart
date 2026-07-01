import 'package:flutter/material.dart';

class NoteDetailScreen extends StatelessWidget {
  const NoteDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detalle de nota')),
      body: const Center(child: Text('Pantalla provisional de detalle de nota.')),
    );
  }
}
