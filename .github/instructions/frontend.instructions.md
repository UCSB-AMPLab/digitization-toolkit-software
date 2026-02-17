---
applyTo: "frontend/**"
---

# Specific instructions for frontend development.

## Styles

- All styles should be written in the `frontend/static` directory, particularly in the `app.css` file.
- Use CSS variables for colors and other reusable values to maintain consistency across the application.
- Follow a modular approach to CSS, organizing styles by components or sections of the application.
- Ensure that styles are responsive and work well on different screen sizes.
- If available, use `frontend/static/example.css` as a reference for styling, color palette, and layout.

## Project Specific Guidelines

- The defaul screen is a 7-inch display, so all styles should be optimized for that size. However, the application should also be responsive and adapt to larger screens when necessary.
- When adding new styles, make sure to test them on the default screen size to ensure they look good and function properly. Additionally, consider how the styles will affect the user experience on different devices and screen sizes.
- Two screen resolutions are supported: 800x480 and 1024x600. Ensure that your styles are compatible with both resolutions, providing a seamless experience for users regardless of the device they are using.
