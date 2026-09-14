# Configuración de la transcripción de audio

## Arquitectura

La aplicación crea `HttpAudioSegmentTranscriber` en `NewNoteScreen` y obtiene su
URL exclusivamente de la constante de compilación `AUDIO_TRANSCRIPTION_ENDPOINT`.
No hay un valor predeterminado deliberadamente: una compilación que no recibe la
constante se detiene antes de hacer la petición con
`transcription_endpoint_not_configured`.

`functions/src/index.ts` implementa la Function HTTPS de segunda generación
`transcribe` en `europe-west1`. Valida el Firebase ID token, acepta el campo
multipart `file` (M4A, MP4, WAV o MP3, máximo 20 MB) y llama al proveedor desde
el servidor. No utiliza Firestore.

La credencial sólo se almacena como secreto `OPENAI_API_KEY` en Google Secret
Manager. Para configurarla y desplegar:

```sh
firebase functions:secrets:set OPENAI_API_KEY
firebase deploy --only functions:transcribe --project sansebas-nexus
```

Al desplegar, Firebase CLI muestra la URL HTTPS real de la función. Debe usarse
esa URL; el repositorio no incorpora una URL de servicio como valor
predeterminado.

## Configuración de una compilación

Una vez desplegado o identificado el proxy seguro existente, se proporciona su
URL (sin claves ni tokens en la propia URL) al compilar o ejecutar:

```sh
flutter run \
  --dart-define=AUDIO_TRANSCRIPTION_ENDPOINT=<URL_HTTPS_REAL_DE_TRANSCRIBE>

flutter build apk \
  --dart-define=AUDIO_TRANSCRIPTION_ENDPOINT=<URL_HTTPS_REAL_DE_TRANSCRIBE>

flutter build appbundle \
  --dart-define=AUDIO_TRANSCRIPTION_ENDPOINT=<URL_HTTPS_REAL_DE_TRANSCRIBE>
```

El endpoint debe aceptar una petición `multipart/form-data` con el archivo en el
campo `file`, autenticar/autorizar la petición según la infraestructura del
backend y devolver JSON con la forma:

```json
{"text": "Texto transcrito"}
```

El cliente obtiene bajo demanda el ID token del usuario actual de Firebase y lo
envía como Bearer; no lo persiste. El backend custodia la credencial y elige el
modelo. Audio y transcripción permanecen fuera de Firestore hasta que el usuario
guarda normalmente la nota.

La URL se registra sin `userinfo`, parámetros de consulta ni fragmento. Las
cabeceras de autorización nunca se registran y las respuestas mostradas como
vista previa ocultan campos de token, autorización, API key y transcripción.
