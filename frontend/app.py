import os
import requests
import streamlit as st

api_base = os.getenv("API_BASE_URL", "http://backend:8000")

st.set_page_config(page_title="Square Calculator", page_icon="🔢")
st.title("Square Calculator")
st.caption("FastAPI + Redis + Celery demo")

number = st.number_input("Enter an integer", step=1, value=2)

if st.button("Submit Task", type="primary"):
    try:
        response = requests.post(
            f"{api_base}/square",
            json={"number": int(number)},
            timeout=10,
        )
        response.raise_for_status()
        data = response.json()
        st.session_state["task_id"] = data["task_id"]
        st.success(f"Task submitted: {data['task_id']}")
    except Exception as exc:
        st.error(f"Failed to submit task: {exc}")

if "task_id" in st.session_state:
    task_id = st.session_state["task_id"]
    st.write(f"Current task: `{task_id}`")

    if st.button("Check Status"):
        try:
            status_resp = requests.get(f"{api_base}/task/{task_id}", timeout=10)
            status_resp.raise_for_status()
            task_data = status_resp.json()
            st.json(task_data)
        except Exception as exc:
            st.error(f"Failed to fetch status: {exc}")
