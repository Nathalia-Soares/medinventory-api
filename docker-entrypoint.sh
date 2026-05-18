#!/bin/sh

# Docker Entrypoint Script
# Runs database migrations before starting the application

set -e

echo "Starting MedInventory API..."

# Check if DATABASE_URL is set
if [ -z "$DATABASE_URL" ]; then
  echo "ERROR: DATABASE_URL environment variable is not set"
  exit 1
fi

echo "DATABASE_URL is configured"

# Run Prisma migrations
echo "Running database migrations..."
npx prisma migrate deploy

if [ $? -eq 0 ]; then
  echo "Migrations completed successfully"
else
  echo "Migration failed"
  exit 1
fi

# Start the application (nest build output varies: dist/src/main.js vs dist/main.js)
if [ -f dist/src/main.js ]; then
  MAIN=dist/src/main.js
elif [ -f dist/main.js ]; then
  MAIN=dist/main.js
else
  echo "ERROR: compiled entrypoint not found under dist/"
  exit 1
fi

echo "Starting NestJS application ($MAIN)..."
exec node "$MAIN"
