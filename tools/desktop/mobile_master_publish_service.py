"""Publish Sansebas Nexus Knowledge masters to Firebase Firestore.

This module is intentionally desktop-side only: it reads the local Knowledge
SQLite database and writes an operational copy of master data to Firestore for
Sansebas Nexus Mobile. It never deletes Firestore documents.
"""

from __future__ import annotations

import argparse
import logging
import re
import sqlite3
import time
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence

DEFAULT_FIREBASE_CREDENTIALS_PATH = Path(
    r"C:\Firebase Sync\Sansebas Nexus Mobile datos\sansebas-nexus-firebase.json"
)
SOURCE = "nexus_desktop"

LOGGER = logging.getLogger(__name__)


class MobileMasterPublishError(RuntimeError):
    """Raised when masters cannot be published to Firestore."""


@dataclass(frozen=True)
class MasterItem:
    id: str
    name: str
    active: bool = True
    order: int = 0
    area_id: str | None = None


@dataclass
class PublishSummary:
    areas_published: int = 0
    topics_published: int = 0
    types_published: int = 0
    tags_published: int = 0
    errors: int = 0
    duration_seconds: float = 0.0
    warnings: list[str] = field(default_factory=list)

    def user_message(self) -> str:
        return (
            f"Áreas publicadas: {self.areas_published}\n"
            f"Temas publicados: {self.topics_published}\n"
            f"Tipos publicados: {self.types_published}\n"
            f"Etiquetas publicadas: {self.tags_published}\n"
            f"Errores: {self.errors}\n"
            f"Duración: {self.duration_seconds:.2f} segundos"
        )


def firestore_safe_id(value: str, fallback_prefix: str = "item") -> str:
    normalized = unicodedata.normalize("NFKD", value.strip())
    ascii_value = normalized.encode("ascii", "ignore").decode("ascii")
    safe = re.sub(r"[^a-zA-Z0-9_-]+", "_", ascii_value.lower()).strip("_")
    safe = re.sub(r"_+", "_", safe)
    return safe or fallback_prefix


class MobileMasterPublishService:
    def __init__(
        self,
        sqlite_path: str | Path,
        firebase_credentials_path: str | Path = DEFAULT_FIREBASE_CREDENTIALS_PATH,
        logger: logging.Logger | None = None,
    ) -> None:
        self.sqlite_path = Path(sqlite_path)
        self.firebase_credentials_path = Path(firebase_credentials_path)
        self.logger = logger or LOGGER

    def publish(self) -> PublishSummary:
        started_at = time.monotonic()
        summary = PublishSummary()
        try:
            db = self._connect_firestore()
            masters = self._read_local_masters(summary)
            summary.areas_published = self._publish_collection(db, "areas", masters["areas"])
            summary.topics_published = self._publish_collection(db, "topics", masters["topics"])
            summary.types_published = self._publish_collection(db, "types", masters["types"])
            summary.tags_published = self._publish_collection(db, "tags", masters["tags"])
        except Exception:
            summary.errors += 1
            self.logger.exception("No se pudieron publicar los maestros móviles")
            raise
        finally:
            summary.duration_seconds = time.monotonic() - started_at
        return summary

    def _connect_firestore(self) -> Any:
        if not self.firebase_credentials_path.exists():
            raise MobileMasterPublishError(
                "No existe el archivo de credenciales Firebase Admin SDK: "
                f"{self.firebase_credentials_path}"
            )
        try:
            import firebase_admin
            from firebase_admin import credentials, firestore
        except ImportError as exc:
            raise MobileMasterPublishError(
                "No está instalado firebase-admin. Instala la dependencia en el entorno de escritorio."
            ) from exc

        try:
            app_name = "sansebas_nexus_mobile_masters"
            try:
                app = firebase_admin.get_app(app_name)
            except ValueError:
                cred = credentials.Certificate(str(self.firebase_credentials_path))
                app = firebase_admin.initialize_app(cred, name=app_name)
            return firestore.client(app=app)
        except Exception as exc:
            raise MobileMasterPublishError(f"No se pudo conectar con Firebase Firestore: {exc}") from exc

    def _read_local_masters(self, summary: PublishSummary) -> dict[str, list[MasterItem]]:
        if not self.sqlite_path.exists():
            raise MobileMasterPublishError(f"No existe la base local Knowledge: {self.sqlite_path}")
        with sqlite3.connect(self.sqlite_path) as conn:
            conn.row_factory = sqlite3.Row
            tables = self._tables(conn)
            areas = self._read_named_table(conn, tables, ["areas", "knowledge_areas", "km_areas"], "area")
            topics = self._read_topics(conn, tables, areas)
            types = self._read_named_table(conn, tables, ["types", "note_types", "knowledge_types", "km_types"], "type")
            tags = self._read_named_table(conn, tables, ["tags", "frequent_tags", "knowledge_tags", "km_tags"], "tag")
        for key, values in {"áreas": areas, "temas": topics, "tipos": types, "etiquetas": tags}.items():
            if not values:
                warning = f"No se encontraron {key} locales para publicar."
                summary.warnings.append(warning)
                self.logger.warning(warning)
        return {"areas": areas, "topics": topics, "types": types, "tags": tags}

    def _tables(self, conn: sqlite3.Connection) -> set[str]:
        rows = conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall()
        return {str(row[0]).lower() for row in rows}

    def _read_named_table(
        self, conn: sqlite3.Connection, tables: set[str], candidates: Sequence[str], fallback_prefix: str
    ) -> list[MasterItem]:
        table = next((candidate for candidate in candidates if candidate.lower() in tables), None)
        if not table:
            return []
        rows = conn.execute(f'SELECT * FROM "{table}"').fetchall()
        return [self._item_from_row(row, fallback_prefix) for row in rows if self._row_name(row)]

    def _read_topics(self, conn: sqlite3.Connection, tables: set[str], areas: Sequence[MasterItem]) -> list[MasterItem]:
        table = next((candidate for candidate in ["topics", "temas", "knowledge_topics", "km_topics"] if candidate in tables), None)
        if not table:
            return []
        area_by_raw_id = {area.id: area.id for area in areas}
        topics: list[MasterItem] = []
        for row in conn.execute(f'SELECT * FROM "{table}"').fetchall():
            name = self._row_name(row)
            if not name:
                continue
            area_value = self._first_present(row, ["area_id", "area", "area_name", "category_id"])
            area_id = firestore_safe_id(str(area_value), "area") if area_value else None
            area_id = area_by_raw_id.get(area_id, area_id)
            topics.append(self._item_from_row(row, "topic", area_id=area_id))
        return topics

    def _item_from_row(self, row: sqlite3.Row, fallback_prefix: str, area_id: str | None = None) -> MasterItem:
        name = self._row_name(row) or fallback_prefix
        raw_id = self._first_present(row, ["id", "uuid", "key", "slug", "code"])
        item_id = firestore_safe_id(str(raw_id or name), fallback_prefix)
        active_value = self._first_present(row, ["active", "is_active", "enabled"])
        order_value = self._first_present(row, ["order", "sort_order", "position", "display_order"])
        return MasterItem(
            id=item_id,
            name=name,
            active=self._parse_bool(active_value),
            order=int(order_value) if order_value is not None and str(order_value).isdigit() else 0,
            area_id=area_id,
        )

    def _parse_bool(self, value: Any | None) -> bool:
        if value is None:
            return True
        if isinstance(value, str):
            return value.strip().lower() not in {"0", "false", "no", "n", "inactive", "inactivo"}
        return bool(value)

    def _row_name(self, row: sqlite3.Row) -> str | None:
        value = self._first_present(row, ["name", "nombre", "title", "label", "value"])
        return str(value).strip() if value is not None and str(value).strip() else None

    def _first_present(self, row: sqlite3.Row, names: Iterable[str]) -> Any | None:
        keys = {key.lower(): key for key in row.keys()}
        for name in names:
            key = keys.get(name.lower())
            if key is not None and row[key] is not None:
                return row[key]
        return None

    def _publish_collection(self, db: Any, collection: str, items: Sequence[MasterItem]) -> int:
        count = 0
        for item in items:
            payload: dict[str, Any] = {
                "id": item.id,
                "name": item.name,
                "active": item.active,
                "order": item.order,
                "updated_at": datetime.now(timezone.utc),
                "source": SOURCE,
            }
            if collection == "topics":
                payload["area_id"] = item.area_id
            db.collection("nexus_masters").document(collection).collection("items").document(item.id).set(payload, merge=True)
            count += 1
            self.logger.info("Publicado maestro móvil %s/%s", collection, item.id)
        return count


def configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def main() -> int:
    parser = argparse.ArgumentParser(description="Publica maestros de Knowledge Manager en Firestore.")
    parser.add_argument("sqlite_path", help="Ruta de la base SQLite/local de Knowledge Manager")
    parser.add_argument("--credentials", default=str(DEFAULT_FIREBASE_CREDENTIALS_PATH), help="Ruta JSON Firebase Admin SDK")
    args = parser.parse_args()
    configure_logging()
    try:
        summary = MobileMasterPublishService(args.sqlite_path, args.credentials).publish()
    except MobileMasterPublishError as exc:
        LOGGER.error("%s", exc)
        return 1
    print(summary.user_message())
    for warning in summary.warnings:
        print(f"Aviso: {warning}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
