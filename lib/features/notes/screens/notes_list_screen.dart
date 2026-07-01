import 'package:flutter/material.dart';

class NotesListScreen extends StatelessWidget {
  const NotesListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      appBar: AppBar(title: Text('Lista de notas')),
      body: Center(child: Text('Pantalla provisional para listar notas.')),
    );
  }
}
