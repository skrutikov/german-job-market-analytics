# Airflow runtime
FROM apache/airflow:3.4.0

# The DHI Python runtime requires linux-libc-dev through its libc and Python
# development packages, so this package cannot be purged independently.
# Upgrade it to a patched Debian version while preserving those dependencies.
USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends --only-upgrade linux-libc-dev \
    && rm -rf /var/lib/apt/lists/*

USER airflow

COPY requirements.txt /requirements.txt
COPY airflow/requirements.txt /airflow-requirements.txt

RUN pip install --no-cache-dir \
    -r /requirements.txt \
    -r /airflow-requirements.txt

COPY --chown=airflow:root pyproject.toml /opt/airflow/pyproject.toml
COPY --chown=airflow:root src /opt/airflow/src
COPY --chown=airflow:root airflow/dags /opt/airflow/dags

RUN pip install --no-cache-dir --no-deps -e /opt/airflow

# Explicitly enforce the non-root runtime user.
USER airflow
