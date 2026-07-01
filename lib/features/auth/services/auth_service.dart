import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

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
  ) async {
    final trimmedEmail = email.trim();
    debugPrint('AuthService.signIn: email=$trimmedEmail');

    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: trimmedEmail,
        password: password,
      );

      final user = credential.user;
      debugPrint('AuthService.signIn: uid=${user?.uid ?? 'null'}');

      if (user == null) {
        await signOut();
        throw const AuthLoginException('Error inesperado.');
      }

      await _validateUserAuthorization(user);
      return credential;
    } on FirebaseAuthException catch (error) {
      throw AuthLoginException(_firebaseAuthMessage(error));
    } on FirebaseException catch (error) {
      debugPrint(
        'AuthService.signIn: Firebase error while validating nexus_mobile_users: ${error.code}',
      );
      await signOut();
      throw AuthLoginException(_firebaseConnectionMessage(error));
    } on AuthAuthorizationException catch (error) {
      throw AuthLoginException(error.message);
    } on AuthLoginException {
      rethrow;
    } catch (error) {
      debugPrint('AuthService.signIn: unexpected error=$error');
      await signOut();
      throw const AuthLoginException('Error inesperado.');
    }
  }

  Future<void> signOut() => _auth.signOut();

  Future<void> validateCurrentUserAuthorization() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthAuthorizationException('No hay una sesión activa');
    }

    await _validateUserAuthorization(user);
  }

  Future<void> _validateUserAuthorization(User user) async {
    debugPrint('AuthService.authorization: uid=${user.uid}');

    final doc = await _firestore
        .collection('nexus_mobile_users')
        .doc(user.uid)
        .get();

    debugPrint(
      'AuthService.authorization: nexus_mobile_users/${user.uid} exists=${doc.exists}',
    );

    if (!doc.exists) {
      await signOut();
      throw const AuthAuthorizationException(
        'Usuario no autorizado para Nexus Mobile',
      );
    }

    final data = doc.data();
    final isActive = data?['active'] == true;
    debugPrint('AuthService.authorization: active=$isActive');

    if (!isActive) {
      await signOut();
      throw const AuthAuthorizationException('Usuario desactivado');
    }
  }

  String _firebaseAuthMessage(FirebaseAuthException error) {
    return switch (error.code) {
      'user-not-found' || 'wrong-password' || 'invalid-credential' ||
      'invalid-email' =>
        'Correo o contraseña incorrectos.',
      'too-many-requests' => 'Demasiados intentos. Espera unos minutos.',
      'network-request-failed' => 'Error de conexión con Firebase.',
      _ => 'Error inesperado.',
    };
  }

  String _firebaseConnectionMessage(FirebaseException error) {
    return switch (error.code) {
      'unavailable' || 'deadline-exceeded' || 'network-request-failed' =>
        'Error de conexión con Firebase.',
      _ => 'Error inesperado.',
    };
  }
}

class AuthLoginException implements Exception {
  const AuthLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AuthAuthorizationException implements Exception {
  const AuthAuthorizationException(this.message);

  final String message;

  @override
  String toString() => message;
}
