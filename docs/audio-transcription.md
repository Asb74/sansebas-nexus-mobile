# Configuración de la transcripción de audio

## Arquitectura auditada

La aplicación crea `HttpAudioSegmentTranscriber` en `NewNoteScreen` y obtiene su
URL exclusivamente de la constante de compilación `AUDIO_TRANSCRIPTION_ENDPOINT`.
No hay un valor predeterminado deliberadamente: una compilación que no recibe la
constante se detiene antes de hacer la petición con
`transcription_endpoint_not_configured`.

Este repositorio no contiene Cloud Functions, otro backend, un proxy de OpenAI,
un servicio de IA reutilizable, una configuración `.env` ni credenciales de
OpenAI. Firebase se usa para autenticación, Firestore y Storage, pero no hay una
función de transcripción declarada. Por tanto, no es posible deducir de forma
segura una URL real o un modelo desde el código disponible. Tampoco se debe usar
una URL directa de OpenAI: eso exigiría distribuir la API key en la aplicación.

## Configuración de una compilación

Una vez desplegado o identificado el proxy seguro existente, se proporciona su
URL (sin claves ni tokens en la propia URL) al compilar o ejecutar:

```sh
flutter run \
  --dart-define=AUDIO_TRANSCRIPTION_ENDPOINT=https://<backend>/transcription
```

El endpoint debe aceptar una petición `multipart/form-data` con el archivo en el
campo `file`, autenticar/autorizar la petición según la infraestructura del
backend y devolver JSON con la forma:

```json
{"text": "Texto transcrito"}
```

El backend es responsable de elegir el modelo de transcripción y de custodiar
sus credenciales. El cliente no envía una API key ni selecciona un modelo. Si el
proxy real exige autenticación Firebase u otro contrato, ese contrato debe
incorporarse cuando se facilite la implementación o especificación del proxy;
no debe suponerse ni inventarse en la aplicación.

La URL se registra sin `userinfo`, parámetros de consulta ni fragmento. Las
cabeceras de autorización nunca se registran y las respuestas mostradas como
vista previa ocultan campos de token, autorización, API key y transcripción.
