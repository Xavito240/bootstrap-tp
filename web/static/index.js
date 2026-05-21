// web/static/index.js — Liste des workspaces : gestion delete (avec force).
(() => {
  async function doDelete(name, force) {
    const url = `/workspaces/${encodeURIComponent(name)}/delete${force ? "?force=1" : ""}`;
    const r = await fetch(url, { method: "POST" });
    return { ok: r.ok, status: r.status, body: await r.json() };
  }

  document.querySelectorAll('button[data-action="delete"]').forEach(btn => {
    btn.addEventListener("click", async () => {
      const name = btn.dataset.ws;
      if (!confirm(`Supprimer définitivement le workspace "${name}" ?\nLes credentials, l'état et le projet généré seront perdus.`)) return;

      btn.disabled = true;
      btn.textContent = "Suppression…";

      try {
        let result = await doDelete(name, false);

        // Si refus car running, proposer le force-delete
        if (!result.ok && result.body && result.body.can_force) {
          const ok = confirm(
            `${result.body.error}\n\n` +
            `Forcer la suppression ? Le process en cours (s'il existe) sera tué.`
          );
          if (!ok) {
            btn.disabled = false;
            btn.textContent = "Supprimer";
            return;
          }
          btn.textContent = "Force…";
          result = await doDelete(name, true);
        }

        if (result.ok) {
          const card = document.querySelector(`.ws-card[data-ws="${name}"]`);
          if (card) {
            card.style.transition = "opacity 0.3s";
            card.style.opacity = "0";
          }
          setTimeout(() => location.reload(), 300);
        } else {
          alert("Suppression échouée : " + (result.body?.error || `HTTP ${result.status}`));
          btn.disabled = false;
          btn.textContent = "Supprimer";
        }
      } catch (e) {
        alert("Erreur réseau : " + e.message);
        btn.disabled = false;
        btn.textContent = "Supprimer";
      }
    });
  });
})();
