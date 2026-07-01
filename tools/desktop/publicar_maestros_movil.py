"""Small desktop button for publishing Knowledge masters to Firestore."""

from __future__ import annotations

import logging
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from mobile_master_publish_service import DEFAULT_FIREBASE_CREDENTIALS_PATH, MobileMasterPublishError, MobileMasterPublishService

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


class PublishMastersApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Sansebas Nexus - Publicar maestros móvil")
        self.resizable(False, False)
        self.sqlite_path = tk.StringVar()
        self.credentials_path = tk.StringVar(value=str(DEFAULT_FIREBASE_CREDENTIALS_PATH))
        self.status = tk.StringVar(value="Selecciona la base Knowledge y pulsa Publicar maestros móvil.")
        self._build()

    def _build(self) -> None:
        frame = ttk.Frame(self, padding=16)
        frame.grid(row=0, column=0, sticky="nsew")
        ttk.Label(frame, text="Base Knowledge SQLite").grid(row=0, column=0, sticky="w")
        ttk.Entry(frame, textvariable=self.sqlite_path, width=72).grid(row=1, column=0, padx=(0, 8), pady=(4, 12))
        ttk.Button(frame, text="Buscar…", command=self._pick_sqlite).grid(row=1, column=1, pady=(4, 12))
        ttk.Label(frame, text="Credenciales Firebase Admin SDK").grid(row=2, column=0, sticky="w")
        ttk.Entry(frame, textvariable=self.credentials_path, width=72).grid(row=3, column=0, padx=(0, 8), pady=(4, 12))
        ttk.Button(frame, text="Buscar…", command=self._pick_credentials).grid(row=3, column=1, pady=(4, 12))
        ttk.Button(frame, text="Publicar maestros móvil", command=self._publish).grid(row=4, column=0, columnspan=2, pady=(0, 12))
        ttk.Label(frame, textvariable=self.status, wraplength=560).grid(row=5, column=0, columnspan=2, sticky="w")

    def _pick_sqlite(self) -> None:
        path = filedialog.askopenfilename(title="Seleccionar base Knowledge", filetypes=[("SQLite", "*.db *.sqlite *.sqlite3"), ("Todos", "*.*")])
        if path:
            self.sqlite_path.set(path)

    def _pick_credentials(self) -> None:
        path = filedialog.askopenfilename(title="Seleccionar JSON Firebase", filetypes=[("JSON", "*.json"), ("Todos", "*.*")])
        if path:
            self.credentials_path.set(path)

    def _publish(self) -> None:
        sqlite = Path(self.sqlite_path.get().strip())
        credentials = Path(self.credentials_path.get().strip())
        if not sqlite.exists():
            messagebox.showerror("Publicar maestros móvil", f"No existe la base Knowledge: {sqlite}")
            return
        if not credentials.exists():
            messagebox.showerror("Publicar maestros móvil", f"No existe el JSON Firebase Admin SDK: {credentials}")
            return
        self.status.set("Publicando maestros móviles…")
        self.update_idletasks()
        try:
            summary = MobileMasterPublishService(sqlite, credentials).publish()
        except MobileMasterPublishError as exc:
            self.status.set("Error al publicar maestros móviles.")
            messagebox.showerror("Publicar maestros móvil", str(exc))
            return
        except Exception as exc:  # Keep the desktop app responsive on unexpected failures.
            logging.exception("Error inesperado publicando maestros móviles")
            self.status.set("Error inesperado al publicar maestros móviles.")
            messagebox.showerror("Publicar maestros móvil", f"Error inesperado: {exc}")
            return
        message = summary.user_message()
        if summary.warnings:
            message += "\n\n" + "\n".join(f"Aviso: {warning}" for warning in summary.warnings)
        self.status.set("Publicación terminada.")
        messagebox.showinfo("Publicar maestros móvil", message)


if __name__ == "__main__":
    PublishMastersApp().mainloop()
