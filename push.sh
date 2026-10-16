#!/usr/bin/env bash
# Sube todos los cambios a GitHub con un mensaje de commit aleatorio.
# Uso:
#   ./push.sh                 -> mensaje aleatorio
#   ./push.sh "mi mensaje"    -> usa tu propio mensaje
cd "$(dirname "$0")" || exit 1

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: esta carpeta no es un repositorio git."
  exit 1
fi

MENSAJES=(
  "Pequeños ajustes"
  "Mejoras varias"
  "Limpieza de código"
  "Arreglos menores"
  "Actualización del proyecto"
  "Retoques finales"
  "Cambios de último momento"
  "Optimizaciones varias"
  "Un poco de orden"
  "Más mejoras"
  "Detalles pulidos"
  "Funciona mejor ahora"
  "Ajustes de rutina"
  "Refactor ligero"
  "Pequeño empujón al proyecto"
)

if [ -n "$1" ]; then
  MENSAJE="$1"
else
  MENSAJE="${MENSAJES[RANDOM % ${#MENSAJES[@]}]}"
fi

git add -A

if git diff --cached --quiet; then
  echo "No hay cambios nuevos para subir."
  exit 0
fi

echo "Commit: $MENSAJE"
git commit -m "$MENSAJE" || exit 1

if git push; then
  echo
  echo "Subido a GitHub correctamente."
else
  echo
  echo "ERROR: falló el push. Revisa tu conexión o tus credenciales de GitHub."
  exit 1
fi
