const { fontFamily } = require('tailwindcss/defaultTheme');

const files = process.env.FILES_PACKAGE;

/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [`${files}/**/*.html`],
  theme: {
    extend: {
      fontFamily: {
        mono: ['Fira Mono', 'Consolas', 'Monaco', 'Andale Mono', 'monospace'],
        sans: ['Fira Sans', 'sans-serif']
      },
      typography: (theme) => ({
        DEFAULT: {
          css: {
            'pre code': {
              fontFamily: 'Fira Mono'
            }
          }
        }
      })
    }
  },
  plugins: [require('@tailwindcss/typography')]
};

