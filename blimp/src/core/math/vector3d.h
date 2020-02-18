#pragma once

struct Vector3D
{
	union {
		float v[3];
		struct
		{
			float x, y, z;
		};
	};

	inline Vector3D(float x = 0.0f, float y = 0.0f, float z = 0.0f);

	inline float length() const;
	inline float length_squared() const;
	inline Vector3D normalize() const;

	inline static Vector3D zero();

	inline Vector3D &operator+=(const Vector3D &vec);
	inline Vector3D &operator-=(const Vector3D &vec);
	inline Vector3D &operator*=(const Vector3D &vec);
	inline Vector3D &operator/=(const Vector3D &vec);
};
inline Vector3D operator+(const Vector3D &left, const Vector3D &right);
inline Vector3D operator-(const Vector3D &left, const Vector3D &right);
inline Vector3D operator*(const Vector3D &left, const Vector3D &right);
inline Vector3D operator*(const Vector3D &left, float right);
inline Vector3D operator*(float left, const Vector3D &right);
inline Vector3D operator/(const Vector3D &left, float right);
inline float dot(const Vector3D &left, const Vector3D &right);

inline Vector3D::Vector3D(float x, float y, float z)
	: x(x), y(y), z(z) {}

inline float Vector3D::length() const
{
	return sqrt(x * x + y * y + z * z);
}

inline float Vector3D::length_squared() const
{
	return x * x + y * y + z * z;
}

inline Vector3D Vector3D::normalize() const
{
	return *this / length();
}

inline Vector3D Vector3D::zero()
{
	return Vector3D(0.0f, 0.0f, 0.0f);
}

inline Vector3D &Vector3D::operator+=(const Vector3D &vec)
{
	this->x += vec.x;
	this->y += vec.y;
	this->z += vec.z;
	return *this;
}

inline Vector3D &Vector3D::operator-=(const Vector3D &vec)
{
	this->x -= vec.x;
	this->y -= vec.y;
	this->z -= vec.z;
	return *this;
}

inline Vector3D &Vector3D::operator*=(const Vector3D &vec)
{
	this->x *= vec.x;
	this->y *= vec.y;
	this->z *= vec.z;
	return *this;
}

inline Vector3D &Vector3D::operator/=(const Vector3D &vec)
{
	this->x /= vec.x;
	this->y /= vec.y;
	this->z /= vec.z;
	return *this;
}

inline Vector3D operator+(const Vector3D &left, const Vector3D &right)
{
	return Vector3D(left.x + right.x, left.y + right.y, left.z + right.z);
}

inline Vector3D operator-(const Vector3D &left, const Vector3D &right)
{
	return Vector3D(left.x - right.x, left.y - right.y, left.z - right.z);
}

inline Vector3D operator*(const Vector3D &left, const Vector3D &right)
{
	return Vector3D(left.x * right.x, left.y * right.y, left.z * right.z);
}

inline Vector3D operator*(const Vector3D &left, float right)
{
	return Vector3D(left.x * right, left.y * right, left.z * right);
}

inline Vector3D operator*(float left, const Vector3D &right)
{
	return right * left;
}

inline Vector3D operator/(const Vector3D &left, float right)
{
	return Vector3D(left.x / right, left.y / right, left.z / right);
}

inline float dot(const Vector3D &left, const Vector3D &right)
{
	return left.x * right.x + left.y * right.y + left.z * right.z;
}