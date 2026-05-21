// web/static/app.js — Édition d'un workspace : validation + submit AJAX.

(() => {
  const form = document.getElementById("bootstrap-form");
  const errorsBox = document.getElementById("form-errors");
  const authSelect = document.getElementById("OVH_AUTH_METHOD");
  const sshKeyField = document.querySelector('[data-field="OVH_SSH_KEY_PATH"]');
  const sshPwdField = document.querySelector('[data-field="OVH_PASSWORD"]');
  const sudoHelpToggle = document.getElementById("show-sudo-help");
  const sudoHelpBlock = document.getElementById("sudo-help");
  const resetBtn = document.getElementById("reset-btn");

  const runUrl = form.dataset.runUrl;
  const resetUrl = form.dataset.resetUrl;
  const workspace = form.dataset.workspace;

  // ----- Affichage conditionnel des champs d'auth SSH ----------------------
  function updateAuthFields() {
    const method = authSelect.value;
    sshKeyField.dataset.hidden = method !== "key";
    sshPwdField.dataset.hidden = method !== "password";
    sshKeyField.querySelector("input").required = method === "key";
    sshPwdField.querySelector("input").required = method === "password";
  }
  authSelect.addEventListener("change", updateAuthFields);
  updateAuthFields();

  // ----- Toggle aide sudo --------------------------------------------------
  if (sudoHelpToggle) {
    sudoHelpToggle.addEventListener("click", (e) => {
      e.preventDefault();
      sudoHelpBlock.classList.toggle("hidden");
      const user = document.getElementById("OVH_USER").value || "devops";
      sudoHelpBlock.textContent = sudoHelpBlock.textContent.replace(/\{utilisateur\}/g, user);
    });
  }

  // ----- Reset -------------------------------------------------------------
  resetBtn.addEventListener("click", async () => {
    if (!confirm(`Effacer toutes les données du workspace "${workspace}" ?`)) return;
    try {
      const r = await fetch(resetUrl, { method: "POST" });
      if (r.ok) {
        location.reload();
      } else {
        const j = await r.json();
        showError("Reset impossible : " + (j.error || r.statusText));
      }
    } catch (e) {
      showError("Erreur réseau : " + e.message);
    }
  });

  // ----- Submit ------------------------------------------------------------
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    hideError();

    const submitBtn = form.querySelector("button[type=submit]");
    submitBtn.disabled = true;
    submitBtn.textContent = "Lancement…";

    const formData = new FormData(form);
    try {
      const r = await fetch(runUrl, { method: "POST", body: formData });
      const j = await r.json();

      if (!r.ok) {
        showError(j.error || "Erreur inconnue", j.missing);
        submitBtn.disabled = false;
        submitBtn.textContent = "Lancer le bootstrap →";
        return;
      }
      window.location.href = j.redirect;
    } catch (e) {
      showError("Erreur réseau : " + e.message);
      submitBtn.disabled = false;
      submitBtn.textContent = "Lancer le bootstrap →";
    }
  });

  function showError(message, missing) {
    let html = "<strong>" + escapeHtml(message) + "</strong>";
    if (missing && missing.length) {
      html += "<ul>" + missing.map(m => "<li>" + escapeHtml(m) + "</li>").join("") + "</ul>";
    }
    errorsBox.innerHTML = html;
    errorsBox.classList.remove("hidden");
    errorsBox.scrollIntoView({ behavior: "smooth", block: "center" });
  }
  function hideError() {
    errorsBox.classList.add("hidden");
  }
  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[c]));
  }
})();
