-- ==============================================================================
-- SOLUCIÓN AL ERROR: "Database error saving new user" EN SUPABASE (GOOGLE OAUTH)
-- ==============================================================================
-- Este script soluciona el fallo cuando un nuevo usuario inicia sesión con Google.
-- Garantiza que el trigger en auth.users no aborte la transacción aunque falten campos
-- o existan restricciones de clave foránea en la tabla profiles o users.

-- 1. Función manejadora robusta con SECURITY DEFINER y control de excepciones
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER 
LANGUAGE plpgsql 
SECURITY DEFINER 
SET search_path = public
AS $$
DECLARE
  v_full_name TEXT;
  v_username TEXT;
  v_avatar TEXT;
BEGIN
  -- Extraer nombre desde los metadatos que envía Google
  v_full_name := COALESCE(
    NEW.raw_user_meta_data->>'full_name',
    NEW.raw_user_meta_data->>'name',
    SPLIT_PART(NEW.email, '@', 1),
    'Estudiante Campus'
  );

  -- Generar username seguro y único
  v_username := LOWER(
    REGEXP_REPLACE(SPLIT_PART(NEW.email, '@', 1), '[^a-zA-Z0-9._-]', '', 'g')
  ) || '_' || SUBSTRING(NEW.id::text, 1, 4);

  -- Extraer foto de perfil de Google si está disponible
  v_avatar := COALESCE(
    NEW.raw_user_meta_data->>'avatar_url',
    NEW.raw_user_meta_data->>'picture',
    ''
  );

  -- A. Registrar en public.users (si la tabla existe)
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'users') THEN
    INSERT INTO public.users (id, email, role, is_verified, is_active)
    VALUES (
      NEW.id,
      NEW.email,
      'student',
      TRUE,
      TRUE
    )
    ON CONFLICT (id) DO UPDATE 
    SET email = EXCLUDED.email,
        is_verified = TRUE;
  END IF;

  -- B. Registrar en public.profiles (si la tabla existe)
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'profiles') THEN
    INSERT INTO public.profiles (
      user_id,
      username,
      full_name,
      avatar_url,
      university,
      career,
      profile_completed
    )
    VALUES (
      NEW.id,
      v_username,
      v_full_name,
      v_avatar,
      'Universidad Central (Sede Principal)',
      'Ingeniería de Software',
      FALSE
    )
    ON CONFLICT (user_id) DO UPDATE
    SET full_name = COALESCE(public.profiles.full_name, EXCLUDED.full_name),
        avatar_url = CASE WHEN public.profiles.avatar_url IS NULL OR public.profiles.avatar_url = '' THEN EXCLUDED.avatar_url ELSE public.profiles.avatar_url END;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Si ocurre cualquier error, registrar aviso en los logs pero NO cancelar la transacción
  -- Esto evita el error 500 "Database error saving new user"
  RAISE WARNING 'Aviso en handle_new_user: %', SQLERRM;
  RETURN NEW;
END;
$$;

-- 2. Eliminar trigger anterior si existe y crear el nuevo
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
