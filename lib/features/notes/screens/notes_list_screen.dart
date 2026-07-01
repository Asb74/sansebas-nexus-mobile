import 'package:flutter/material.dart';

class NotesListScreen extends StatelessWidget {
  const NotesListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lista de notas')),
      body: const Center(child: Text('Pantalla provisional para listar notas.')),
    );
  }
}
