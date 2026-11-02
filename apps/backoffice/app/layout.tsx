import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Gestión | Agencia",
  description: "Entorno local de desarrollo de la gestión comercial",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="es">
      <body>{children}</body>
    </html>
  );
}
