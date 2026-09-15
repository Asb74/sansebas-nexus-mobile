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

## Persistencia, recuperación y segmentación

Cada captura se conserva en `app_flutter/recordings/<UUID>/`. Su `session.json`
es un manifiesto local escrito mediante temporal y copia de respaldo, con UUID,
fechas, estado, duración, asociación a la nota, error, transcripción,
`transcription_applied` y estado/ruta/tamaño/transcripción de cada segmento.
Firestore no se usa como journal y los errores recuperables no eliminan audio.

Los segmentos no son cortes de bytes: el recorder se detiene y finaliza cada
contenedor M4A antes de iniciar el siguiente. Cada archivo enviado es por ello
un M4A autocontenido. Los segmentos completados se omiten al reintentar y sus
textos se unen por índice. En DEBUG se puede reducir el rollover sin alterar el
límite de producción de 20 MiB:

```sh
flutter run --dart-define=AUDIO_SEGMENTATION_THRESHOLD_BYTES=150000 \
  --dart-define=AUDIO_TRANSCRIPTION_ENDPOINT=<URL>
```

Android ejecuta durante la captura un foreground service de tipo `microphone`,
con notificación persistente. `paused` e `inactive` no detienen la grabación.
Un Force Stop explícito puede detener cualquier servicio Android; al arrancar
se buscan M4A finalizados y las sesiones huérfanas pasan a error recuperable.
Una transcripción persistida y aún no aplicada se añade una sola vez.

## Checklist manual Android

1. Grabar 20 s, detener y comprobar la transcripción.
2. Grabar, bloquear 30 s, desbloquear, detener y escuchar todo el intervalo.
3. Grabar, cambiar de app 30 s, volver, detener y escuchar todo el intervalo.
4. Hacer dos grabaciones en la misma nota y comprobar texto A + texto B.
5. Escribir texto manual, grabar y comprobar que permanece.
6. Cortar la red, comprobar que el M4A existe, restaurarla y reintentar.
7. Matar el proceso tras persistir la respuesta y comprobar una única aplicación.
8. Probar `adb shell am kill com.sansebas.nexus.mobile` y, por separado,
   Force Stop desde Ajustes, sin esperar que este último mantenga el servicio.
