import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Catálogo | Agencia",
  description: "Entorno local de desarrollo del catálogo",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="es">
      <body>{children}</body>
    </html>
  );
}
