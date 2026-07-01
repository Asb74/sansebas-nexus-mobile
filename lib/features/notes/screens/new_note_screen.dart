import 'package:flutter/material.dart';

class NewNoteScreen extends StatelessWidget {
  const NewNoteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nueva nota')),
      body: const Center(child: Text('Pantalla provisional para crear una nueva nota.')),
    );
  }
}
