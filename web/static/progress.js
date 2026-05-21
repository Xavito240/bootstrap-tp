// web/static/progress.js — SSE listener + mise à jour live des étapes/logs.

(() => {
  const body = document.body;
  const eventsUrl = body.dataset.eventsUrl;
  const stateUrl  = body.dataset.stateUrl;
  const stopUrl   = body.dataset.stopUrl;

  const statusLine = document.getElementById("status-line");
  const logOutput = document.getElementById("log-output");
  const logStatus = document.getElementById("log-status");
  const successModal = document.getElementById("success-modal");
  const successLinks = document.getElementById("success-links");
  const stopBtn = document.getElementById("stop-btn");
  const steps = Array.from(document.querySelectorAll(".step"));

  let firstChunk = true;

  // ----- État initial ------------------------------------------------------
  fetch(stateUrl).then(r => r.json()).then((s) => {
    s.completed.forEach(markStepDone);
    updateActiveStep();
    if (!s.running && s.completed.length === s.total) {
      onComplete();
    } else if (!s.running && s.completed.length === 0) {
      statusLine.textContent = "Aucun bootstrap en cours.";
      logStatus.textContent = "idle";
    }
  });

  // ----- SSE ---------------------------------------------------------------
  const es = new EventSource(eventsUrl);
  logStatus.textContent = "live";
  logStatus.classList.add("live");

  es.addEventListener("open", () => {
    logStatus.textContent = "live";
    logStatus.classList.add("live");
    logStatus.classList.remove("error");
  });

  es.addEventListener("error", () => {
    logStatus.textContent = "déconnecté";
    logStatus.classList.remove("live");
    logStatus.classList.add("error");
  });

  es.addEventListener("message", (e) => {
    const msg = JSON.parse(e.data);
    if (msg.type === "log") {
      appendLog(msg.line);
    } else if (msg.type === "step") {
      markStepDone(msg.id);
      updateActiveStep();
    } else if (msg.type === "done") {
      onComplete();
      es.close();
    }
  });

  // ----- Stop --------------------------------------------------------------
  stopBtn.addEventListener("click", async () => {
    if (!confirm("Arrêter le bootstrap en cours ?")) return;
    try {
      await fetch(stopUrl, { method: "POST" });
      logStatus.textContent = "arrêté";
      logStatus.classList.remove("live");
    } catch (e) {
      alert("Erreur : " + e.message);
    }
  });

  // ----- Helpers -----------------------------------------------------------
  function appendLog(line) {
    if (firstChunk) {
      logOutput.textContent = "";
      firstChunk = false;
    }
    logOutput.textContent += line + "\n";
    logOutput.scrollTop = logOutput.scrollHeight;
  }

  function markStepDone(stepId) {
    const el = document.querySelector(`.step[data-step-id="${stepId}"]`);
    if (!el) return;
    el.classList.add("done");
    el.classList.remove("active");
    el.querySelector(".step-icon").textContent = "✓";
  }

  function updateActiveStep() {
    let firstPending = -1;
    for (let i = 0; i < steps.length; i++) {
      if (!steps[i].classList.contains("done")) {
        firstPending = i;
        break;
      }
    }
    if (firstPending === -1) return;
    steps.forEach((s, i) => {
      s.classList.toggle("active", i === firstPending);
    });
    const lbl = steps[firstPending].querySelector(".step-label").textContent;
    statusLine.textContent = "En cours : " + lbl;
  }

  function onComplete() {
    const allDone = steps.every(s => s.classList.contains("done"));
    logStatus.textContent = allDone ? "terminé" : "interrompu";
    logStatus.classList.remove("live");
    logStatus.classList.add(allDone ? "done" : "error");

    statusLine.textContent = allDone
      ? "🎉 Bootstrap terminé avec succès"
      : "⚠ Bootstrap interrompu, voir les logs";
    stopBtn.disabled = true;

    if (allDone) {
      const text = logOutput.textContent;
      const repoMatch = text.match(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+/);
      const apiMatch = text.match(/http:\/\/[\w.\-]+\/api\/health/);

      const links = [];
      if (apiMatch) {
        const host = apiMatch[0].replace("/api/health", "");
        links.push(`<a href="${host}/" target="_blank">🌍 Application : ${host}/</a>`);
        links.push(`<a href="${apiMatch[0]}" target="_blank">♡ Health : ${apiMatch[0]}</a>`);
      }
      if (repoMatch) {
        links.push(`<a href="${repoMatch[0]}" target="_blank">⎇ Dépôt : ${repoMatch[0]}</a>`);
        links.push(`<a href="${repoMatch[0]}/actions" target="_blank">⚒ CI/CD</a>`);
      }
      successLinks.innerHTML = links.map(l => "<li>" + l + "</li>").join("");
      successModal.classList.remove("hidden");
    }
  }
})();
