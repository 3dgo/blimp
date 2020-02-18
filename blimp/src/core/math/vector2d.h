#pragma once

struct Vector2D
{
	union {
		float v[2];
		struct
		{
			float x, y;
		};
	};

	inline Vector2D(float x = 0.0f, float y = 0.0f);

	inline float length() const;
	inline float length_squared() const;
	inline Vector2D normalize() const;

	inline static Vector2D zero();

	inline Vector2D &operator+=(const Vector2D &vec);
	inline Vector2D &operator-=(const Vector2D &vec);
	inline Vector2D &operator*=(const Vector2D &vec);
	inline Vector2D &operator/=(const Vector2D &vec);
};
inline Vector2D operator+(const Vector2D &left, const Vector2D &right);
inline Vector2D operator-(const Vector2D &left, const Vector2D &right);
inline Vector2D operator*(const Vector2D &left, const Vector2D &right);
inline Vector2D operator*(const Vector2D &left, float right);
inline Vector2D operator*(float left, const Vector2D &right);
inline Vector2D operator/(const Vector2D &left, float right);
inline float dot(const Vector2D &left, const Vector2D &right);

inline Vector2D::Vector2D(float x, float y)
	: x(x), y(y) {}

inline float Vector2D::length() const
{
	return sqrt(x * x + y * y);
}

inline float Vector2D::length_squared() const
{
	return x * x + y * y;
}

inline Vector2D Vector2D::normalize() const
{
	return *this / length();
}

inline Vector2D Vector2D::zero()
{
	return Vector2D(0.0f, 0.0f);
}

inline Vector2D &Vector2D::operator+=(const Vector2D &vec)
{
	this->x += vec.x;
	this->y += vec.y;
	return *this;
}

inline Vector2D &Vector2D::operator-=(const Vector2D &vec)
{
	this->x -= vec.x;
	this->y -= vec.y;
	return *this;
}

inline Vector2D &Vector2D::operator*=(const Vector2D &vec)
{
	this->x *= vec.x;
	this->y *= vec.y;
	return *this;
}

inline Vector2D &Vector2D::operator/=(const Vector2D &vec)
{
	this->x /= vec.x;
	this->y /= vec.y;
	return *this;
}

inline Vector2D operator+(const Vector2D &left, const Vector2D &right)
{
	return Vector2D(left.x + right.x, left.y + right.y);
}

inline Vector2D operator-(const Vector2D &left, const Vector2D &right)
{
	return Vector2D(left.x - right.x, left.y - right.y);
}

inline Vector2D operator*(const Vector2D &left, const Vector2D &right)
{
	return Vector2D(left.x * right.x, left.y * right.y);
}

inline Vector2D operator*(const Vector2D &left, float right)
{
	return Vector2D(left.x * right, left.y * right);
}

inline Vector2D operator*(float left, const Vector2D &right)
{
	return right * left;
}

inline Vector2D operator/(const Vector2D &left, float right)
{
	return Vector2D(left.x / right, left.y / right);
}

inline float dot(const Vector2D &left, const Vector2D &right)
{
	return left.x * right.x + left.y * right.y;
}