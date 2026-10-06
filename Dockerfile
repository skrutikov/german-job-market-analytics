FROM python:3.12-slim

WORKDIR /app

# We intentionally do NOT copy the whole project yet.
# This allows Docker to cache the installed dependencies.
COPY requirements.txt .

ARG INSTALL_DEV=false

# 1. Upgrade pip.
# 2. Install project dependencies.
# 3. Optionally install development tools.
RUN python -m pip install --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt \
    && if [ "$INSTALL_DEV" = "true" ]; then \
        pip install --no-cache-dir black pytest; \
    fi

# Since requirements were already installed,
# Docker usually only repeats this step after source code changes,
# making rebuilds much faster.
COPY . .

ENV RUNNING_IN_DOCKER=1
# Without this, print() output may appear several seconds later.
# Very useful for Docker logs.
ENV PYTHONUNBUFFERED=1
# Install the project package from the src layout while keeping imports linked to the source tree.
RUN pip install --no-cache-dir --no-deps -e .

# FastAPI (This is documentation only.)
EXPOSE 8000
# Dash frontend (This is documentation only.)
EXPOSE 8050

# Run "sh /app/entrypoint.sh"
CMD ["sh", "/app/entrypoint.sh"]