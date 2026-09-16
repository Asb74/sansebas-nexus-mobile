# Contrato de grabaciones persistentes

## Auditoría y causa original

El guardado de `NewNoteScreen` convertía correctamente cada segmento en un
`MobileAttachment`, pero inmediatamente excluía todos los adjuntos cuyo
`captureMode` era `audio`. Firestore recibía la transcripción en el documento de
la nota, mientras que Firebase Storage nunca recibía los M4A. Además,
`session.json` sólo modelaba el estado de transcripción y una sesión podía dejar
de aparecer como pendiente —o permitir su borrado— sin que existiera una copia
remota del audio.

La solución reutiliza la colección `attachments` y el servicio Storage
existentes; no introduce una segunda cola ni guarda bytes/base64 en Firestore.

## Contrato móvil/PC

Cada nota puede incluir `recordings`, una lista de grabaciones lógicas. Cada
elemento contiene `recording_id`, fechas, duración y tamaño totales,
`segment_count`, `transcription_status`, `upload_status` y `segments`. Los
segmentos sólo contienen índice, nombre, MIME, tamaño, duración,
`storage_path` y estado. `local_audio_path` sólo vive en `session.json`.

Los objetos se almacenan individualmente en:

```text
users/<uid>/nexus_mobile_notes/<noteId>/audio/<recordingId>/segment_0000.m4a
```

El PC debe agrupar por `recording_id`, ordenar por `segment_index`, descargar
cada `storage_path` con Firebase Auth y presentar una sola grabación. Si
`upload_status == uploaded` y `transcription_status != completed`, debe mostrar
“Audio pendiente de transcripción”. Este repositorio no contiene el código del
cliente PC, por lo que su descargador/UI no se puede modificar aquí.

## Reintentos y borrado

Tras confirmar cada `putFile`, el segmento se marca `uploaded` atómicamente en
`session.json`. Un reintento omite esos segmentos y conserva su ruta estable.
No se escribe progreso de bytes en Firestore. Al terminar, las referencias de
todos los adjuntos y el estado final de la nota se confirman en un solo batch.

Una sesión sólo puede borrarse mediante `deleteSession` cuando todos sus
segmentos están confirmados como `uploaded`. Las sesiones transcritas pero aún
locales siguen formando parte de `pendingSessions` después de reiniciar.

No hace falta migración destructiva: documentos antiguos sin `recordings`
siguen deserializándose como una lista vacía. Para desplegar las reglas (fuera
de esta entrega): `firebase deploy --only storage`.
