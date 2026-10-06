FROM apache/airflow:3.3.0

COPY requirements.txt /requirements.txt
COPY airflow/requirements.txt /airflow-requirements.txt

RUN pip install --no-cache-dir \
    -r /requirements.txt \
    -r /airflow-requirements.txt

COPY pyproject.toml /opt/airflow/pyproject.toml
COPY src /opt/airflow/src
COPY airflow/dags /opt/airflow/dags

RUN pip install --no-cache-dir --no-deps -e /opt/airflow
