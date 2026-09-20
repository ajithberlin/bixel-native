// Bixel Studio Landing Page JavaScript

document.addEventListener('DOMContentLoaded', () => {
  // 1. Copy terminal command
  const copyBtn = document.getElementById('copy-cmd-btn');
  const codeEl = document.getElementById('terminal-code-text');

  if (copyBtn && codeEl) {
    copyBtn.addEventListener('click', async () => {
      const textToCopy = codeEl.innerText.trim();
      try {
        await navigator.clipboard.writeText(textToCopy);
        const originalHtml = copyBtn.innerHTML;
        copyBtn.innerHTML = '✓ Copied!';
        copyBtn.style.color = '#00ff88';
        setTimeout(() => {
          copyBtn.innerHTML = originalHtml;
          copyBtn.style.color = '';
        }, 2000);
      } catch (err) {
        console.error('Failed to copy: ', err);
      }
    });
  }

  // 2. Realtime GitHub Stars Loader
  const repo = 'ajithberlin/bixel-native';
  const cacheKey = `gh_stars_${repo}`;
  const starCountEls = document.querySelectorAll('.github-stars-count');

  const updateStarsUI = (count) => {
    starCountEls.forEach((el) => {
      el.textContent = count;
      el.style.display = 'inline-flex';
    });
  };

  const cachedStars = sessionStorage.getItem(cacheKey);
  if (cachedStars) {
    updateStarsUI(cachedStars);
  }

  fetch(`https://api.github.com/repos/${repo}`)
    .then((res) => {
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json();
    })
    .then((data) => {
      if (typeof data.stargazers_count === 'number') {
        const count = data.stargazers_count >= 1000
          ? (data.stargazers_count / 1000).toFixed(1).replace(/\.0$/, '') + 'k'
          : data.stargazers_count.toString();
        sessionStorage.setItem(cacheKey, count);
        updateStarsUI(count);
      }
    })
    .catch((err) => {
      // Graceful fallback: if API rate limited or offline, keep default star icon
      if (!cachedStars) {
        starCountEls.forEach(el => el.style.display = 'none');
      }
    });
});
