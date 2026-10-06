FROM apache/airflow:3.3.0

COPY requirements.txt /requirements.txt
COPY airflow/requirements.txt /airflow-requirements.txt

RUN pip install --no-cache-dir \
    -r /requirements.txt \
    -r /airflow-requirements.txt

COPY --chown=airflow:root pyproject.toml /opt/airflow/pyproject.toml
COPY --chown=airflow:root src /opt/airflow/src
COPY --chown=airflow:root airflow/dags /opt/airflow/dags

RUN pip install --no-cache-dir --no-deps -e /opt/airflow
