import 'package:flutter/material.dart';

class NewNoteScreen extends StatelessWidget {
  const NewNoteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      appBar: AppBar(title: Text('Nueva nota')),
      body: Center(child: Text('Pantalla provisional para crear una nueva nota.')),
    );
  }
}
