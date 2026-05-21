// web/static/new.js — Création d'un nouveau workspace.
(() => {
  const form = document.getElementById("new-form");
  const errorsBox = document.getElementById("form-errors");

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    errorsBox.classList.add("hidden");

    const submitBtn = form.querySelector("button[type=submit]");
    submitBtn.disabled = true;
    submitBtn.textContent = "Création…";

    const formData = new FormData(form);
    try {
      const r = await fetch("/new", { method: "POST", body: formData });
      const j = await r.json();
      if (!r.ok) {
        errorsBox.textContent = j.error || "Erreur inconnue";
        errorsBox.classList.remove("hidden");
        submitBtn.disabled = false;
        submitBtn.textContent = "Créer →";
        return;
      }
      window.location.href = j.redirect;
    } catch (err) {
      errorsBox.textContent = "Erreur réseau : " + err.message;
      errorsBox.classList.remove("hidden");
      submitBtn.disabled = false;
      submitBtn.textContent = "Créer →";
    }
  });
})();
