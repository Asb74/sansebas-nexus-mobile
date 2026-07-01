import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  AuthService({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential> signInWithEmailAndPassword(
    String email,
    String password,
  ) {
    return _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> signOut() => _auth.signOut();

  Future<void> validateCurrentUserAuthorization() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw AuthAuthorizationException('No hay una sesión activa');
    }

    final doc = await _firestore
        .collection('nexus_mobile_users')
        .doc(user.uid)
        .get();

    if (!doc.exists) {
      await signOut();
      throw AuthAuthorizationException(
        'Usuario no autorizado para Nexus Mobile',
      );
    }

    final data = doc.data();
    if (data == null || data['active'] != true) {
      await signOut();
      throw AuthAuthorizationException('Usuario desactivado');
    }
  }
}

class AuthAuthorizationException implements Exception {
  const AuthAuthorizationException(this.message);

  final String message;

  @override
  String toString() => message;
}
